# Copyright (c) 2026, NL-BIOMERO contributors.
# BSD 2-Clause License; see LICENSE.
"""Regression coverage for detached control records in the deployment gate."""
import contextlib
import io
from pathlib import Path
import sys
import os
import subprocess
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch


class ActiveWorkTests(unittest.TestCase):
    def classify(self, tasks: list, workflows: dict) -> str:
        """Run the worker probe against representative persisted records."""
        source = (Path(__file__).parents[1] / "scripts/check-active-work.sh").read_text()
        probe = source.split("<<'PYTHON'\n", 1)[1].split("\nPYTHON", 1)[0]
        records = {task.id: task for task in tasks}
        records.update(workflows)
        repository = SimpleNamespace(get=lambda identifier: records[identifier])
        client = SimpleNamespace(workflowTracker=SimpleNamespace(repository=repository))
        rows = [SimpleNamespace(task_id=task.id) for task in tasks]
        query = SimpleNamespace(filter_by=lambda **kwargs: SimpleNamespace(all=lambda: rows))
        session = SimpleNamespace(query=lambda model: query,
                                  execute=lambda statement: SimpleNamespace(scalar=lambda: "on"))
        biomero = ModuleType("biomero")
        biomero.SlurmClient = SimpleNamespace(from_config=lambda **kwargs: contextlib.nullcontext(client))
        database = ModuleType("biomero.database")
        database.EngineManager = SimpleNamespace(get_session=lambda: session)
        database.TaskExecution = object
        sqlalchemy = ModuleType("sqlalchemy")
        sqlalchemy.text = lambda statement: statement
        events = ModuleType("biomero.eventsourcing")
        events.is_launcher_task = lambda task: task.launcher
        output = io.StringIO()
        with patch.dict(sys.modules, {"biomero": biomero, "biomero.database": database,
                                      "biomero.eventsourcing": events, "sqlalchemy": sqlalchemy}), contextlib.redirect_stdout(output):
            exec(compile(probe, "active-work-probe", "exec"), {})
        return output.getvalue().strip()

    def test_terminal_launcher_is_not_running_work(self):
        for terminal in ("DONE", "FAILED"):
            with self.subTest(terminal=terminal):
                task = SimpleNamespace(id="launcher", launcher=True, workflow_id="workflow")
                self.assertEqual(self.classify([task], {"workflow": SimpleNamespace(finished=True)}),
                                 "ACTIVE_WORK_COUNTS=0,1")

    def test_running_workflow_launcher_still_blocks(self):
        task = SimpleNamespace(id="launcher", launcher=True, workflow_id="workflow")
        self.assertEqual(self.classify([task], {"workflow": SimpleNamespace(finished=False)}),
                         "ACTIVE_WORK_COUNTS=1,0")

    def test_unfinished_execution_still_blocks_with_terminal_launcher(self):
        tasks = [SimpleNamespace(id="launcher", launcher=True, workflow_id="workflow"),
                 SimpleNamespace(id="import", launcher=False)]
        self.assertEqual(self.classify(tasks, {"workflow": SimpleNamespace(finished=True)}),
                         "ACTIVE_WORK_COUNTS=1,1")

    def test_missing_parent_does_not_produce_an_idle_result(self):
        task = SimpleNamespace(id="launcher", launcher=True, workflow_id="missing")
        with self.assertRaises(KeyError):
            self.classify([task], {})

    def test_shell_gate_retains_unfinished_count_on_probe_failure(self):
        for probe in ("error", "malformed"):
            with self.subTest(probe=probe), tempfile.TemporaryDirectory() as directory:
                sudo = Path(directory) / "sudo"
                sudo.write_text("""#!/bin/bash
case "$*" in
  *"SELECT count(*) FROM biomero_task_execution"*) echo 1 ;;
  *"SELECT count(*) FROM (SELECT DISTINCT"*) echo 0 ;;
  *"default_transaction_read_only=on"*)
    if [[ "$PROBE_RESULT" == error ]]; then exit 1; fi
    echo malformed ;;
  *"squeue -u"*) exit 0 ;;
  *) exit 99 ;;
esac
""")
                sudo.chmod(0o755)
                result = subprocess.run(
                    ["bash", "scripts/check-active-work.sh", "--require-idle"],
                    cwd=Path(__file__).parents[1], capture_output=True, text=True,
                    env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                         "PROBE_RESULT": probe}, timeout=10)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("unfinished tasks=1", result.stdout)
                self.assertIn("NOT TESTED:", result.stdout)


if __name__ == "__main__":
    unittest.main()
