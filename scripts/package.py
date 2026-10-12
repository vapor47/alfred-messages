#!/usr/bin/env python3
"""Build-time only: generate Alfred's native workflow metadata."""
import pathlib, plistlib, subprocess, uuid
ROOT = pathlib.Path(__file__).resolve().parent.parent
WF = ROOT / 'workflow'
objects, connections, positions = [], {}, {}
# One-time identity change resets this list object's learned ordering. Keep stable
# on subsequent builds; conversation UIDs still preserve exact routing/selection.
LIST_UID = '5CB415F8-44F2-40AF-9436-346CB3B79122' 

def obj(uid, type_, config, version=1, x=0, y=0):
    objects.append(dict(uid=uid, type='alfred.workflow.' + type_, config=config, version=version))
    positions[uid] = dict(xpos=x, ypos=y)

def link(src, dst, modifiers=0, text='', close=False):
    connections.setdefault(src, []).append(dict(destinationuid=dst, modifiers=modifiers, modifiersubtext=text, vitoclose=close))

obj(LIST_UID, 'input.scriptfilter', dict(keyword='{var:keyword}', argumenttype=1, withspace=True, title='Recent Messages', subtext='Browse and reply to recent conversations', runningsubtext='Reading recent conversations…', script='./run list "$1"', type=0, scriptargtype=1, escaping=0, alfredfiltersresults=False, queuemode=1, queuedelaymode=0, queuedelayimmediatelyinitially=True, argumenttrimmode=0, argumenttreatemptyqueryasnil=True), version=3, x=50, y=50)
obj('VIEW', 'userinterface.text', dict(behaviour=2, fontmode=0, fontsizing=0, footertext='Reply below · ⌥↩ Open Messages', inputfile='text-view', inputtype=1, loadingtext='Loading conversation…', outputmode=1, scriptinput=2, spellchecking=0, stackview=False), x=300, y=50)
link(LIST_UID, 'VIEW')
for uid, action, modifier, text, y in [('COMMAND', 'command-send', 1048576, 'Send reply', 150), ('REFRESH', 'refresh', 262144, 'Refresh with empty draft', 250), ('OPEN', 'open', 524288, 'Open Messages; retain/select draft', 350)]:
    obj(uid, 'utility.argument', dict(argument='{query}', passthroughargument=False, variables={'view_action': action}), x=550, y=y)
    link('VIEW', 'REFRESH_GUARD' if uid == 'REFRESH' else uid, modifier, text if uid != 'REFRESH' else 'Refresh only with empty reply field', True)
    link(uid, 'VIEW')
# For this native Text View path, vitoclose=true suppresses hiding before outgoing actions.
# Re-entry clears native input. Only refresh an empty draft; otherwise retain the existing view.
condition = '649F841F-178B-4A22-A5D9-DF731D512119'
obj('REFRESH_GUARD', 'utility.conditional', dict(conditions=[dict(inputstring='', matchcasesensitive=True, matchmode=0, matchstring='', outputlabel='Empty draft', uid=condition)], elselabel='Draft present', hideelse=False), x=500, y=250)
link('REFRESH_GUARD', 'REFRESH')
connections['REFRESH_GUARD'][-1]['sourceoutputuid'] = condition
obj('REFRESH_BLOCKED', 'output.notification', dict(title='Messages', text='Refresh paused while a draft is present. Send or clear the draft first.', lastpathcomponent=False, onlyshowifquerypopulated=False, removeextension=False), x=750, y=300)
link('REFRESH_GUARD', 'REFRESH_BLOCKED')
# No automatic Text View reruns are emitted. Native Return is translated to an explicit return-send action.
# Return reruns the Text View's executable, preserving the visible history. Command-Return uses the modifier branch.
settings = []
for variable, label, default, description in [
    ('keyword', 'Conversation keyword', 'msg', 'Lists recent conversations.'),
    ('cache_mode', 'Cache mode', 'disk', 'disk, memory, or off. Changes apply on the next invocation; leaving disk deletes cached transcripts and avatars.'),
    ('send_key', 'Send key', 'return', 'return or command-return. In command-return mode, plain Return cannot send.'),
    ('conversation_limit', 'Recent conversations', '8', '1–200, default 8. A More conversations row pages through older chats.'),
    ('message_limit', 'Messages per conversation', '10', '1–200, default 10.'),
]:
    settings.append(dict(variable=variable, label=label, description=description, type='textfield', config=dict(default=default, placeholder=default, required=True, trim=True)))
for setting in settings:
    if setting['variable'] == 'cache_mode':
        setting.update(type='popupbutton', config=dict(default='disk', pairs=[['Disk — default', 'disk'], ['Memory only', 'memory'], ['Off', 'off']]))
    if setting['variable'] == 'send_key':
        setting.update(type='popupbutton', config=dict(default='return', pairs=[['Return', 'return'], ['Command-Return', 'command-return']]))
ids = {item['uid']: str(uuid.uuid5(uuid.NAMESPACE_URL, 'dev.local.alfred-messages/' + item['uid'])).upper() for item in objects}
for item in objects: item['uid'] = ids[item['uid']]
connections = {ids[source]: [dict(edge, destinationuid=ids[edge['destinationuid']]) for edge in edges] for source, edges in connections.items()}
positions = {ids[key]: value for key, value in positions.items()}
plist = dict(bundleid='dev.local.alfred-messages', name='Messages', createdby='Joseph', description='Recent Messages and contextual replies with optional caching', category='Productivity', version='0.8.3', disabled=False, objects=objects, connections=connections, uidata=positions, variables=dict(keyword='msg', cache_mode='disk', send_key='return', conversation_limit='8', message_limit='10'), variablesdontexport=[], userconfigurationconfig=settings, readme=(ROOT / 'README.md').read_text())
with (WF / 'info.plist').open('wb') as f: plistlib.dump(plist, f)
app_info = dict(CFBundleIdentifier='dev.local.alfred-messages.helper', CFBundleName='Messages Helper', CFBundleDisplayName='Messages Helper', CFBundleExecutable='MessagesHelper', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='0.1.0', LSMinimumSystemVersion='13.0', LSUIElement=True, NSAppleEventsUsageDescription='Resolve participant names, send replies to your exact selected conversation, and activate Messages.')
with (WF / 'Messages Helper.app/Contents/Info.plist').open('wb') as f: plistlib.dump(app_info, f)
subprocess.run(['/usr/bin/swift', str(ROOT / 'scripts/icon.swift'), str(WF / 'icon.png')], check=True)
subprocess.run(['/usr/bin/swift', str(ROOT / 'scripts/more-icon.swift'), str(WF / 'more.png')], check=True)
