"""Isolated transaction tests: fake Docker calls, never production operations."""
from contextlib import contextmanager
import fcntl
import importlib.util
import multiprocessing
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE=Path(__file__).resolve().parents[1]/'payload/common/privileged_runtime.py'
spec=importlib.util.spec_from_file_location('queue_runtime',SOURCE)
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)


def queued_worker(directory, barrier, events):
    task={'id':'fake','kind':'docker_restart','params':{'container':'synthetic'},'timeout':3}
    def fake(args, timeout):
        events.put(('start',time.monotonic(),timeout))
        time.sleep(.1)
        events.put(('end',time.monotonic(),0))
        return subprocess.CompletedProcess(args,0,'ok','')
    try:
        # Directory security is separately tested; /tmp is deliberately writable.
        with patch.object(runtime,'BASE',Path(directory)),patch.object(runtime,'secure_directory'),patch.object(runtime,'docker_command',side_effect=fake):
            barrier.wait(timeout=5)
            result=runtime.task_docker('u1',task)
            events.put(('result',result.returncode,0))
    except Exception as exc:events.put(('error',str(exc),0))


class QueueTests(unittest.TestCase):
    def task(self,kind='docker_restart',timeout=10):
        return {'id':'fake','kind':kind,'params':{'container':'synthetic','image':'local:fake','name':'fake'},'timeout':timeout}

    def test_simultaneous_tasks_serialize_without_failure(self):
        ctx=multiprocessing.get_context('fork')
        with tempfile.TemporaryDirectory() as directory:
            barrier=ctx.Barrier(3);events=ctx.Queue()
            workers=[ctx.Process(target=queued_worker,args=(directory,barrier,events)) for _ in range(3)]
            try:
                for worker in workers:worker.start()
                for worker in workers:worker.join(8);self.assertEqual(worker.exitcode,0)
                rows=[events.get(timeout=2) for _ in range(9)]
                self.assertEqual(sum(r[0]=='result' and r[1]==0 for r in rows),3,rows)
                ordered=sorted((r for r in rows if r[0] in ('start','end')),key=lambda r:r[1])
                self.assertEqual([r[0] for r in ordered],['start','end']*3)
            finally:
                for worker in workers:
                    if worker.is_alive():worker.terminate();worker.join()
                events.close();events.join_thread()

    def test_busy_timeout_never_issues_a_command(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(runtime,'BASE',Path(directory)),patch.object(runtime,'secure_directory'):
            with runtime.docker_transaction(),patch.object(runtime,'docker_command') as command:
                with self.assertRaisesRegex(runtime.DockerBusyError,'本次未执行 Docker 命令'):
                    runtime.task_docker('u1',self.task(timeout=.12))
                command.assert_not_called()

    def test_interactive_transaction_still_fails_fast(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(runtime,'BASE',Path(directory)),patch.object(runtime,'secure_directory'):
            with runtime.docker_transaction():
                started=time.monotonic()
                with self.assertRaises(runtime.DockerBusyError):
                    with runtime.docker_transaction():self.fail('overlapping mutation')
                self.assertLess(time.monotonic()-started,.1)

    def test_wait_and_inspection_consume_total_timeout(self):
        @contextmanager
        def delayed(wait):
            self.assertEqual(wait,10)
            with patch.object(runtime.time,'monotonic',return_value=103):yield
        with patch.object(runtime.time,'monotonic',return_value=100),patch.object(runtime,'docker_transaction',side_effect=delayed),patch.object(runtime,'docker_command',return_value=subprocess.CompletedProcess([],0,'ok','')) as command:
            runtime.task_docker('u1',self.task())
            self.assertEqual(command.call_args.kwargs['timeout'],7)

    def test_command_failure_is_not_retried(self):
        @contextmanager
        def unlocked(**kwargs):yield
        with patch.object(runtime,'docker_transaction',side_effect=unlocked),patch.object(runtime,'docker_command',side_effect=subprocess.TimeoutExpired('fake',1)) as command:
            with self.assertRaises(subprocess.TimeoutExpired):runtime.task_docker('u1',self.task())
            self.assertEqual(command.call_count,1)


if __name__=='__main__':unittest.main()
