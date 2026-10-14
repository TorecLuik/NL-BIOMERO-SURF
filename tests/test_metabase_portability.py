"""Exercise the actual inline translators without contacting production services."""
import ast
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load_functions(script, namespace):
    source = (ROOT / "scripts" / script).read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
    tree = ast.parse(source)
    functions = ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef)], type_ignores=[])
    exec(compile(functions, script, "exec"), namespace)
    return namespace


class ColumnSettingsPortability(unittest.TestCase):
    def test_restore_then_export_on_different_installations(self):
        definitions = json.loads((ROOT / "metabase/dashboards.json").read_text())
        tile = next(t for t in definitions[0]["cards"]
                    if (t.get("card") or {}).get("name") == "Biomero Workflow Progress")
        portable = tile["visualization_settings"]
        names = ["workflow_id", "group", "start_time", "task", "main_task_name"]
        for offset in (90, 9000):
            ids = {name: offset + i for i, name in enumerate(names)}
            table = {"id": 1, "fields": [{"id": fid, "name": name} for name, fid in ids.items()]}
            restore = load_functions("restore-metabase-dashboards.sh", {
                "json": json, "missing": [],
                "tables": {"BIOMERO": {("public", "biomero_workflow_progress_view"): table}},
            })
            restored = restore["untranslate"](portable)
            columns = restored["column_settings"]
            self.assertEqual(len(columns), 5)
            link_key = json.dumps(["ref", ["field", ids["workflow_id"], None]], separators=(",", ":"))
            self.assertEqual(columns[link_key]["click_behavior"]["linkTemplate"],
                             'http://localhost:4080/webclient/search/?search_query="{{workflow_id}}"')
            self.assertFalse(restore["missing"])
            export = load_functions("export-metabase-dashboards.sh", {
                "json": json,
                "fields": {str(fid): {"field": name, "schema": "public",
                                      "table": "biomero_workflow_progress_view", "database": "BIOMERO"}
                           for name, fid in ids.items()},
            })
            # Compare decoded keys: JSON object ordering is immaterial.
            canonical = lambda s: {json.dumps(json.loads(k), sort_keys=True): v
                                   for k, v in s["column_settings"].items()}
            self.assertEqual(canonical(export["translate"](restored)), canonical(portable))
            native = {"column_settings": {'["name","uuid"]': {"click_behavior": {"type": "link"}}}}
            self.assertEqual(export["translate"](native), native)

    def test_unknown_field_stops_export(self):
        export = load_functions("export-metabase-dashboards.sh", {"json": json, "fields": {}})
        with self.assertRaisesRegex(ValueError, "unresolved Metabase field ID"):
            export["translate"]({"column_settings": {'["ref",["field",2586,null]]': {}}})


if __name__ == "__main__":
    unittest.main()
