#!/usr/bin/env python3
import pathlib, plistlib, subprocess, uuid, zipfile
root = pathlib.Path(__file__).resolve().parent.parent
wf = root / 'workflow'
p = plistlib.load((wf / 'info.plist').open('rb'))
app_info = plistlib.load((wf / 'Messages Helper.app/Contents/Info.plist').open('rb'))
assert 'NSContactsUsageDescription' not in app_info
assert 'participant names' in app_info['NSAppleEventsUsageDescription']
ids = {x['uid'] for x in p['objects']}
assert len(ids) == len(p['objects'])
conversation_list = next(o for o in p['objects'] if o['type'] == 'alfred.workflow.input.scriptfilter' and o['config']['keyword'] == '{var:keyword}')
assert conversation_list['uid'] != str(uuid.uuid5(uuid.NAMESPACE_URL, 'dev.local.alfred-messages/LIST')).upper()
assert not conversation_list['config']['alfredfiltersresults']

for source, edges in p['connections'].items():
    assert source in ids
    for edge in edges: assert edge['destinationuid'] in ids
view = next(x for x in p['objects'] if x['type'] == 'alfred.workflow.userinterface.text' and x['config']['inputfile'] == 'text-view')
assert p['connections'][conversation_list['uid']][0]['destinationuid'] == view['uid']
assert {x['modifiers'] for x in p['connections'][view['uid']]} == {1048576, 262144, 524288}
assert all(edge['modifiers'] != 0 for edge in p['connections'][view['uid']])
assert view['config']['inputtype'] == 1 and view['config']['outputmode'] == 1
refresh_edge = next(e for e in p['connections'][view['uid']] if e['modifiers']==262144)
assert refresh_edge['vitoclose'] is True
refresh_guard = next(o for o in p['objects'] if o['uid']==refresh_edge['destinationuid'])
assert refresh_guard['type']=='alfred.workflow.utility.conditional'
assert refresh_guard['config']['conditions'][0]['matchmode']==0 and refresh_guard['config']['conditions'][0]['matchstring']==''
blocked = next(e for e in p['connections'][refresh_guard['uid']] if 'sourceoutputuid' not in e)
assert next(o for o in p['objects'] if o['uid']==blocked['destinationuid'])['type']=='alfred.workflow.output.notification'
assert view['config']['scriptinput'] == 2 and view['config']['behaviour'] == 2
assert p['variables'] == dict(keyword='msg', cache_mode='disk', send_key='return', conversation_limit='8', message_limit='10')
for variable, choices in [('cache_mode', {'disk', 'memory', 'off'}), ('send_key', {'return', 'command-return'})]:
    config = next(x for x in p['userconfigurationconfig'] if x['variable'] == variable)
    assert config['type'] == 'popupbutton' and {x[1] for x in config['config']['pairs']} == choices
assert not (wf / 'install.sh').exists()
for file in ['run', 'text-view', 'uninstall.sh']:
    assert (wf / file).stat().st_mode & 0o111
binary = 'Messages Helper.app/Contents/MacOS/MessagesHelper'
with zipfile.ZipFile(root / 'dist/Alfred-Messages.alfredworkflow') as archive:
    assert archive.read(binary) == (wf / binary).read_bytes()
    for name in ['info.plist','README.md','docs/VALIDATION.md','docs/fixture-results.json','docs/FUTURE_WORK.md']:
        assert archive.read(name) == (wf / name).read_bytes()
    assert 'install.sh' not in archive.namelist()
    assert 'more.png' in archive.namelist()
    for file in ['run','text-view','uninstall.sh',binary]:
        assert archive.getinfo(file).external_attr >> 16 & 0o111
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(wf / 'Messages Helper.app')],check=True)
print('PASS: native metadata, modifier routing, dropdowns, permissions, archive payloads and app signature')

assert not any(o['type'] == 'alfred.workflow.input.scriptfilter' and '-cache' in o['config'].get('keyword', '') for o in p['objects'])
