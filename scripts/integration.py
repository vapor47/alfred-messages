#!/usr/bin/env python3
"""Synthetic IPC/privacy benchmark. Never reads the user's Messages DB or sends."""
import json, os, pathlib, shutil, sqlite3, statistics, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPER = ROOT / '.build/release/MessagesHelper'
report = {'fixture': '35 conversations × 40 messages; 30/30 limits; synthetic content only', 'output_timings': {}, 'checks': []}
with tempfile.TemporaryDirectory(prefix='am-ipc-', dir='/tmp') as tmp:
    base = pathlib.Path(tmp)
    dbpath = base / 'chat.db'
    db = sqlite3.connect(dbpath)
    db.executescript('''
      PRAGMA journal_mode=WAL;
      CREATE TABLE chat(guid TEXT,display_name TEXT);
      CREATE TABLE handle(id TEXT);
      CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
      CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER,attributedBody BLOB,associated_message_type INTEGER,associated_message_guid TEXT);
      CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
      CREATE TABLE attachment(transfer_name TEXT,mime_type TEXT);
      CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
      CREATE INDEX chat_message_chat ON chat_message_join(chat_id);
      CREATE INDEX attachment_message ON message_attachment_join(message_id);
      CREATE INDEX handle_chat ON chat_handle_join(chat_id);
    ''')
    for c in range(1,36):
        db.execute('INSERT INTO chat VALUES(?,?)', (f'iMessage;+;synthetic-{c}', f'Synthetic group {c} 👋'))
        db.execute('INSERT INTO handle VALUES(?)', (f'test-{c}@example.invalid',))
        db.execute('INSERT INTO chat_handle_join VALUES(?,?)', (c,c))
        for m in range(40):
            row = (c-1)*40+m+1
            db.execute('INSERT INTO message VALUES(?,?,?,?,?,NULL,0,NULL)', (f'synthetic-message-{row}', f'Synthetic Unicode 世界 reply {m}', (800_000_000 + c*100+m)*1_000_000_000, m%2, c))
            db.execute('INSERT INTO chat_message_join VALUES(?,?)', (c,row))
    db.commit()
    env = dict(os.environ, MESSAGES_DATABASE=str(dbpath), MESSAGES_STATE_ROOT=str(base/'state'), MESSAGES_SOCKET_DIR=str(base/'socket'), cache_mode='disk', conversation_limit='30', message_limit='30', send_key='return')
    daemon = None
    def start():
        global daemon
        daemon = subprocess.Popen([str(HELPER),'daemon'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(200):
            if (base/'socket/helper.sock').exists(): return
            if daemon.poll() is not None: raise RuntimeError('daemon exited: ' + daemon.stderr.read().decode())
            time.sleep(.02)
        raise RuntimeError('endpoint timed out')
    def stop():
        global daemon
        if daemon is not None:
            daemon.terminate(); daemon.wait(timeout=5); daemon = None
        (base/'socket/helper.sock').unlink(missing_ok=True)
    def call(operation, arg='', extra=None):
        value = subprocess.check_output([str(HELPER),operation,arg], env=dict(env, **(extra or {})), timeout=70)
        return json.loads(value)
    def ready(mode):
        env['cache_mode'] = mode
        call('configure')
        for _ in range(200):
            value = call('list')
            if len([x for x in value.get('items',[]) if x.get('uid')]) == int(env['conversation_limit']): return value
            time.sleep(.02)
        raise RuntimeError('snapshot timed out')
    def check(condition, name):
        assert condition, name
        report['checks'].append(name)
    try:
        start()
        for mode in ['disk','memory','off']:
            start_time=time.perf_counter(); listing = ready(mode); cold_ms=(time.perf_counter()-start_time)*1000
            durations=[]
            for _ in range(50):
                tick=time.perf_counter(); result=call('list'); durations.append((time.perf_counter()-tick)*1000)
                assert len([x for x in result['items'] if x.get('uid')])==30 and result['items'][-1].get('autocomplete')=='»2 '
            ordered=sorted(durations)
            report['output_timings'][mode]={'configure_to_first_ready_ms': round(cold_ms,2), 'list_warm_p50_ms':round(statistics.median(durations),2), 'list_warm_p95_ms':round(ordered[47],2),'samples':50}
            check(listing['items'][0]['uid']=='iMessage;+;synthetic-35', mode+' preserves exact selected group ID and activity order')
            icons=[x['icon']['path'] for x in listing['items'] if x.get('uid')]
            check(all(x=='icon.png' for x in icons) if mode!='disk' else all('/cache/avatars/' in x for x in icons), mode+' avatar policy')
            if mode!='disk':
                check(not (base/'state/cache').exists(), mode+' has no disk message/contact cache')
                check(set(x.name for x in (base/'state').iterdir())=={'settings.json'}, mode+' persists only non-content settings')
            selected=dict(chat_id=listing['items'][0]['uid'], submission_token='synthetic-token', view_action='history')
            view=call('view','',selected)
            check(view['behaviour']['scroll']=='end' and len(view['response'].split('**Me**'))>1, mode+' renders chronological history')
            plain=call('view','Retained synthetic draft',dict(selected, send_key='command-return', view_action=''))
            check(plain['behaviour']['inputfield']=='select' and 'preserves draft' in plain['footer'], mode+' plain Return cannot submit in Command-Return mode')
            initial=call('view','Retained synthetic draft',selected)
            check(initial['behaviour']['inputfield']=='select', mode+' initial history never submits its input')
            if mode=='off':
                diagnostics=call('diagnostics')
                check(diagnostics['watchers']==0 and diagnostics['cache']['conversations']==0, 'off stops watcher and retains no snapshot')
                benchmark=call('benchmark')
                check(all(not x['disk_io'] for x in benchmark['benchmark']) and not (base/'state/cache').exists(), 'off benchmark respects persistence policy')
                report['reader_render_benchmark']=benchmark['benchmark']
        listing=ready('memory')
        db.execute("UPDATE message SET text='Updated synthetic fixture' WHERE ROWID=1400")
        tick=time.perf_counter(); db.commit()
        for _ in range(100):
            if call('list')['items'][0]['subtitle'].startswith('Updated synthetic fixture'): break
            time.sleep(.02)
        else: raise AssertionError('WAL watcher freshness timeout')
        report['fixture_wal_freshness_ms']=round((time.perf_counter()-tick)*1000,2)
        check(report['fixture_wal_freshness_ms']<2000, 'WAL watcher publishes within two seconds on synthetic fixture')
        listing=ready('memory')
        selected=dict(chat_id=listing['items'][0]['uid'], submission_token='no-send-token', view_action='return-send')
        moved = base/'temporarily-unavailable.db'
        dbpath.rename(moved)
        failed=call('view','Draft must survive failure',selected)
        check(failed['behaviour']['inputfield']=='select' and 'Synthetic group 35' in failed['response'], 'Return submission database failure preserves draft and cached history without running automation')
        moved.rename(dbpath)
        refresh=call('view','Draft retained on refresh',dict(selected, view_action='refresh'))
        check(refresh['behaviour']['inputfield']=='select' and refresh['variables']['submission_token']=='no-send-token', 'explicit refresh retains draft and preserves submission token')
        env['conversation_limit']='5'; env['message_limit']='3'; call('configure')
        reduced=call('list'); check(len([x for x in reduced['items'] if x.get('uid')])==5, 'limit reductions apply immediately')
        history=call('view','',dict(selected,view_action='history'))
        check(history['response'].count('**')==6, 'message reductions apply immediately')
        stop(); start(); listing=ready('memory')
        check(not (base/'state/cache').exists(), 'memory restart rebuilds without persistent content')
        env['cache_mode']='off'; call('configure'); stop(); start()
        check(call('diagnostics')['watchers']==0, 'off restart creates no watchers')
        check(not (base/'state/cache').exists(), 'off restart creates no persistent content')
        report['checks_passed']=len(report['checks'])
    finally:
        stop(); db.close()
(ROOT/'docs/fixture-results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ['checks','reader_render_benchmark']},indent=2))
