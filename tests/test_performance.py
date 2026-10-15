import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import json
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]/'payload'
sys.path[:0]=[str(ROOT/'system'),str(ROOT/'common')]
loader=importlib.machinery.SourceFileLoader('task_perf',str(ROOT/'system/task-center-helper'))
spec=importlib.util.spec_from_loader(loader.name,loader);helper=importlib.util.module_from_spec(spec);loader.exec_module(helper)


class PersistenceTests(unittest.TestCase):
    def test_only_changes_are_persisted(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory=Path(tmp);(directory/'state.json').write_text(json.dumps({'tasks':[],'runs':[]}))
            with patch.object(helper,'home',return_value=directory),patch.object(helper,'atomic',wraps=helper.atomic) as save:
                with helper.database('u1') as state:self.assertEqual(state['tasks'],[])
                save.assert_not_called()
                with helper.database('u1') as state:state['tasks'].append({'id':'one'})
                self.assertEqual(save.call_count,1)
                with helper.database('u1') as state:state['tasks'].append({'id':'two'});state['tasks'].pop()
                self.assertEqual(save.call_count,1)
                with self.assertRaises(ValueError):
                    with helper.database('u1') as state:state['tasks'].clear();raise ValueError('aborted')
                self.assertEqual(save.call_count,1)


if __name__=='__main__':unittest.main()
