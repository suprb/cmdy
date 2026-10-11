import errno
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from CMDYFinishing.owned_worker_ready import wait_owned_worker


class OwnedWorkerReadyTests(unittest.TestCase):
    def test_bound_socket_is_not_ready_until_listening_and_owned_reply(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'worker.sock'
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(path))
                self.assertTrue(path.exists())
                with socket.socket(socket.AF_UNIX) as peer:
                    with self.assertRaises(ConnectionRefusedError):
                        peer.connect(str(path))
                listen = threading.Event()
                errors = []
                def serve():
                    try:
                        if not listen.wait(2):
                            raise TimeoutError('test server was not released')
                        server.listen(1)
                        server.settimeout(2)
                        with server.accept()[0] as peer:
                            self.assertEqual(json.loads(peer.recv(128)), {'command': 'state'})
                            peer.sendall(b'{"pid":123,"parentPID":456}\n')
                    except BaseException as error:
                        errors.append(error)
                thread = threading.Thread(target=serve)
                thread.start()
                def state():
                    with socket.socket(socket.AF_UNIX) as peer:
                        peer.settimeout(2)
                        try:
                            peer.connect(str(path))
                        except ConnectionRefusedError:
                            listen.set()
                            raise
                        peer.sendall(b'{"command":"state"}\n')
                        return json.loads(peer.recv(128))
                try:
                    ready = wait_owned_worker(state, 123, 456, timeout=2)
                finally:
                    listen.set()
                    thread.join(3)
                self.assertFalse(thread.is_alive())
                self.assertEqual(errors, [])
                self.assertGreaterEqual(ready['connectionAttempts'], 2)
                self.assertIn(errno.ECONNREFUSED, ready['transientConnectionErrors'])
                self.assertEqual(ready['state'], {'pid': 123, 'parentPID': 456})

    def test_wrong_pid_or_parent_is_rejected_without_retry(self):
        for state in ({'pid': 124, 'parentPID': 456}, {'pid': 123, 'parentPID': 457}):
            calls = []
            def read():
                calls.append(1)
                return state
            with self.assertRaisesRegex(RuntimeError, 'identity differs'):
                wait_owned_worker(read, 123, 456)
            self.assertEqual(calls, [1])

    def test_non_readiness_errors_are_not_retried(self):
        calls = []
        def read():
            calls.append(1)
            raise PermissionError(errno.EACCES, 'denied')
        with self.assertRaises(PermissionError):
            wait_owned_worker(read, 123, 456)
        self.assertEqual(calls, [1])

    def test_readiness_wait_is_bounded(self):
        def read():
            raise FileNotFoundError(errno.ENOENT, 'not bound')
        with self.assertRaises(TimeoutError):
            wait_owned_worker(read, 123, 456, timeout=.01, poll_seconds=.001)


if __name__ == '__main__':
    unittest.main()
