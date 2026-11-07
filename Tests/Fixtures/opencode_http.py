#!/usr/bin/python3
"""Synthetic V1 HTTP/SSE peer; all persistence is inside the test profile."""
import base64
import json
import os
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

home = os.environ['OPENCODE_CONFIG_DIR']
store = os.path.join(home, 'http-native.json')
auth = 'Basic ' + base64.b64encode(('notch-companion:' + os.environ['OPENCODE_SERVER_PASSWORD']).encode()).decode()
lock = threading.RLock()
sessions, history, statuses, permissions, questions = {}, {}, {}, {}, {}
listeners = []
race_pending = False
receipt_read_error = False
held_events = None
pending_delegation_snapshot = None
if os.path.exists(store):
    with open(store) as f:
        data = json.load(f)
        sessions, history = data['sessions'], data['history']


def save():
    with open(store, 'w') as f:
        json.dump(dict(sessions=sessions, history=history), f)


def event(kind, **props):
    frame = dict(type=kind, properties=props)
    if held_events is not None:
        held_events.append(frame)
        return
    for target in list(listeners):
        target.put(frame)


def release_events():
    global held_events
    frames, held_events = held_events, None
    for frame in frames or []:
        for target in list(listeners):
            target.put(frame)


def done(sid, text, interrupted=False, error=None):
    rows = history[sid]
    model = sessions[sid].get('model', dict(providerID='native', id='default'))
    info = dict(id='msg_response_' + str(len(rows)), sessionID=sid, role='assistant',
                time=dict(created=1, completed=2), finish='stop', providerID=model['providerID'], modelID=model['id'],
                tokens=dict(input=123, output=4, reasoning=0, cache=dict(read=20, write=7)))
    if interrupted:
        info['error'] = dict(name='MessageAbortedError')
    if error:
        info['error'] = error
    rows.append(dict(info=info, parts=[dict(id='part_' + str(len(rows)), sessionID=sid, messageID=info['id'], type='text', text=text)]))
    statuses.pop(sid, None)
    save()
    event('message.updated', sessionID=sid, info=info)
    event('session.status', sessionID=sid, status=dict(type='idle'))


def delegate(sid):
    child = 'ses_child'
    sessions[child] = dict(id=child, parentID=sid, directory=sessions[sid]['directory'], title='Delegated fixture')
    history[child] = [dict(info=dict(id='msg_child_user', sessionID=child, role='user', time=dict(created=1)), parts=[dict(type='text', text='child prompt')])]
    statuses[child] = dict(type='busy')
    event('session.created', info=sessions[child], sessionID=child)
    event('session.status', sessionID=child, status=statuses[child])
    permissions['perm_child'] = dict(id='perm_child', sessionID=child, permission='edit', patterns=['fixture.txt'], metadata={})
    event('permission.asked', **permissions['perm_child'])
    done(sid, 'Parent has replied; child is still waiting')


def split_tail(sid):
    # Each step is one poll: a text tail plus a new call, then a new call plus later text.
    info = dict(id='msg_split', sessionID=sid, role='assistant', time=dict(created=1))
    bash = dict(id='call_bash', type='tool', tool='bash', state=dict(status='completed', input=dict(command='swift test'), output='ok'))
    read = dict(id='call_read', type='tool', tool='read', state=dict(status='completed', input=dict(path='a.swift'), output='ok'))
    head, row = dict(type='text', text="I'll run the tests now."), dict(info=info, parts=[])
    with lock:
        history[sid].append(row)
    for parts in [[dict(type='text', text="I'll run the tests")], [head, bash], [head, bash, read, dict(type='text', text='Found it.')]]:
        with lock:
            row['parts'] = parts
            event('message.updated', sessionID=sid, info=info)
        time.sleep(.3)
    with lock:
        info['time']['completed'] = 2
        statuses.pop(sid, None)
        save()
        event('session.status', sessionID=sid, status=dict(type='idle'))


def work(sid, text):
    time.sleep(.10)
    if text == 'split-tail':
        return split_tail(sid)
    if text == 'session-error':
        with lock:
            event('session.error', sessionID=sid, error=dict(name='ProviderAuthError', data=dict(providerID='native', message='Native provider credentials expired')))
        time.sleep(.2)
    with lock:
        if text == 'delayed-child':
            child = 'ses_child'
            sessions[child] = dict(id=child, parentID=sid, directory=sessions[sid]['directory'], title='Empty child before delayed SSE')
            history[child] = []
            done(sid, 'Parent returned before child startup')
            threading.Thread(target=release_child, daemon=True).start()
        elif text == 'delegate':
            delegate(sid)
        elif text == 'terminal-error':
            # The failure is only on the final message: no session.error frame.
            done(sid, 'Partial answer', error=dict(name='APIError', data=dict(message='Provider rejected the request')))
        elif text == 'question':
            questions['question_root'] = dict(id='question_root', sessionID=sid, questions=[dict(question='Choose color', options=[dict(label='Sage'), dict(label='Pearl')], custom=False, multiple=False)])
            event('question.asked', **questions['question_root'])
        elif text != 'hold':
            done(sid, 'model:' + sessions[sid].get('model', {}).get('id', 'default'))


def release_child():
    release = os.path.join(home, 'release-child')
    for _ in range(500):
        if os.path.exists(release):
            os.unlink(release)
            with lock:
                statuses['ses_child'] = dict(type='busy')
                event('session.status', sessionID='ses_child', status=dict(type='busy'))
            time.sleep(.1)
            with lock:
                done('ses_child', 'Released child settled')
            return
        time.sleep(.01)


def admit_later(sid, body, reject):
    time.sleep(.2)
    with lock:
        if reject:
            event('session.error', sessionID=sid, error=dict(name='UnknownError', data=dict(message='Queue admission failed')))
            return
        sessions[sid]['agent'] = 'native-custom-agent'
        history[sid].append(dict(info=dict(id=body['messageID'], sessionID=sid, role='user', agent='native-custom-agent', time=dict(created=1)), parts=body['parts']))
        statuses[sid] = dict(type='busy')
        save()
        event('session.status', sessionID=sid, status=statuses[sid])
    time.sleep(.1)
    with lock:
        done(sid, 'Queue receipt persisted')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def send_json(self, status, data=None):
        body = b'' if data is None else json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global race_pending, receipt_read_error, pending_delegation_snapshot
        if self.headers.get('Authorization') != auth:
            return self.send_json(401, {})
        path = unquote(urlparse(self.path).path)
        if path == '/event':
            target = queue.Queue()
            listeners.append(target)
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            target.put(dict(type='server.connected', properties={}))
            try:
                while True:
                    frame = target.get(timeout=20)
                    self.wfile.write(('data: ' + json.dumps(frame) + '\n\n').encode())
                    self.wfile.flush()
            except Exception:
                listeners.remove(target)
            return
        with lock:
            if path == '/global/health':
                return self.send_json(200, dict(healthy=True, version='2.0.0' if os.path.exists(os.path.join(home, 'bad-version')) else '1.18.34'))
            if path == '/doc':
                paths = ['/session', '/session/status', '/session/{sessionID}', '/session/{sessionID}/children', '/session/{sessionID}/message', '/session/{sessionID}/prompt_async', '/session/{sessionID}/abort', '/event', '/permission', '/permission/{requestID}/reply', '/question', '/question/{requestID}/reply', '/question/{requestID}/reject', '/provider', '/config']
                return self.send_json(200, dict(paths={x: {} for x in paths}))
            if path == '/provider':
                response = dict(connected=['native'], all=[dict(id='native', models={'default': dict(name='Default', limit=dict(context=8000)), 'selected': dict(name='Selected', limit=dict(context=16000))})])
                for marker, size in [('large-catalog', 6 * 1024 * 1024), ('oversized-catalog', 32 * 1024 * 1024)]:
                    if os.path.exists(os.path.join(home, marker)):
                        response['fixturePadding'] = 'x' * size
                return self.send_json(200, response)
            if path == '/config':
                return self.send_json(200, dict(model='native/default'))
            if path == '/session/status':
                if os.path.exists(os.path.join(home, 'arm-status-race')):
                    os.unlink(os.path.join(home, 'arm-status-race'))
                    race_pending = True
                return self.send_json(200, statuses)
            if path == '/permission':
                return self.send_json(200, list(permissions.values()))
            if path == '/question':
                return self.send_json(200, list(questions.values()))
            bits = path.strip('/').split('/')
            if len(bits) >= 2 and bits[0] == 'session' and bits[1] in sessions:
                sid = bits[1]
                if len(bits) == 2:
                    return self.send_json(200, sessions[sid])
                if bits[2] == 'message':
                    if sid == 'ses_child' and held_events is not None:
                        release_events()
                    marker = os.path.join(home, 'arm-initial-idle-race')
                    if os.path.exists(marker):
                        os.unlink(marker)
                        event('session.status', sessionID=sid, status=dict(type='idle'))
                        time.sleep(.15)
                    if receipt_read_error:
                        receipt_read_error = False
                        return self.send_json(404, {})
                    if sid == 'ses_parent' and race_pending:
                        race_pending = False
                        statuses['ses_child'] = dict(type='busy')
                        event('session.status', sessionID='ses_child', status=dict(type='busy'))
                        threading.Thread(target=release_child, daemon=True).start()
                        time.sleep(.15)
                    return self.send_json(200, history[sid])
                if bits[2] == 'children':
                    children = [x for x in sessions.values() if x.get('parentID') == sid]
                    if pending_delegation_snapshot == sid:
                        # Return the old child list, then let the remaining HTTP
                        # reads observe the new child before its SSE is delivered.
                        pending_delegation_snapshot = None
                        delegate(sid)
                        if sid != 'ses_parent':
                            done('ses_parent', 'Parent replied while its grandchild is waiting')
                    return self.send_json(200, children)
            return self.send_json(404, {})

    def do_POST(self):
        global receipt_read_error, held_events, pending_delegation_snapshot
        if self.headers.get('Authorization') != auth:
            return self.send_json(401, {})
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        body = json.loads(raw) if raw else {}
        path = unquote(urlparse(self.path).path)
        with lock:
            if path == '/session':
                sid = 'ses_parent'
                sessions[sid] = dict(id=sid, directory=unquote(self.headers['x-opencode-directory']), title=body['title'], metadata=body.get('metadata', {}))
                history[sid] = []
                save()
                return self.send_json(200, sessions[sid])
            bits = path.strip('/').split('/')
            if len(bits) == 3 and bits[0] == 'session' and bits[1] in sessions:
                sid = bits[1]
                if bits[2] == 'prompt_async':
                    text = body['parts'][0]['text']
                    if text == 'receipt-read-error':
                        receipt_read_error = True
                        return self.send_json(204)
                    if text in ['queued-delivery', 'queued-rejection']:
                        self.send_json(204)
                        threading.Thread(target=admit_later, args=(sid, body, text == 'queued-rejection'), daemon=True).start()
                        return
                    if history[sid]:
                        assert body.get('agent') == 'native-custom-agent'
                    sessions[sid]['agent'] = body.get('agent', 'native-custom-agent')
                    history[sid].append(dict(info=dict(id=body['messageID'], sessionID=sid, role='user', agent=sessions[sid]['agent'], time=dict(created=1)), parts=body['parts']))
                    if 'model' in body:
                        sessions[sid]['model'] = dict(providerID=body['model']['providerID'], id=body['model']['modelID'])
                    statuses[sid] = dict(type='busy')
                    save()
                    if text in ['delegate-during-snapshot', 'delegate-during-nested-snapshot']:
                        held_events = []
                        pending_delegation_snapshot = sid
                        if text == 'delegate-during-nested-snapshot':
                            intermediate = 'ses_intermediate'
                            sessions[intermediate] = dict(id=intermediate, parentID=sid, directory=sessions[sid]['directory'], title='Intermediate child')
                            history[intermediate] = []
                            done(intermediate, 'Intermediate child initially settled')
                            pending_delegation_snapshot = intermediate
                    event('session.status', sessionID=sid, status=statuses[sid])
                    text = body['parts'][0]['text']
                    self.send_json(204)
                    if text not in ['delegate-during-snapshot', 'delegate-during-nested-snapshot']:
                        threading.Thread(target=work, args=(sid, text), daemon=True).start()
                    return
                if bits[2] == 'abort':
                    if sid in statuses:
                        done(sid, 'cancelled', interrupted=True)
                    return self.send_json(200, True)
            if path == '/permission/perm_child/reply':
                assert body['reply'] == 'reject'
                permissions.pop('perm_child')
                event('permission.replied', sessionID='ses_child', requestID='perm_child')
                done('ses_child', 'Child stopped after denial')
                return self.send_json(200, True)
            if path == '/question/question_root/reply':
                assert body['answers'] == [['Sage']]
                questions.pop('question_root')
                event('question.replied', sessionID='ses_parent', requestID='question_root')
                done('ses_parent', 'Sage')
                return self.send_json(200, True)
            return self.send_json(404, {})


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
print('opencode server listening on http://127.0.0.1:' + str(server.server_port), flush=True)
server.serve_forever()
