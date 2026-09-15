def _nl_biomero_normalize_generated_job_script(job_script: str) -> str:
    """Add output verification to a BIOMERO descriptor-generated Slurm script.

    Injected into ``biomero.slurm_client``. Handles the path where BIOMERO
    builds a script from workflow descriptors. Keep it small: a custom
    ``slurm_script_repo`` is used as provided and is not modified.
    """
    if "set -eo pipefail" not in job_script:
        lines = job_script.splitlines(keepends=True)
        insert_at = 1 if lines and lines[0].startswith("#!") else 0
        for idx, line in enumerate(lines):
            if line.startswith("#SBATCH"):
                insert_at = idx + 1
        lines.insert(insert_at, "set -eo pipefail\n")
        job_script = "".join(lines)

    if "_nl_biomero_verify_outputs" not in job_script:
        output_check = (
            "\n"
            "_nl_biomero_verify_outputs() {\n"
            '    if [ -z "${DATA_PATH:-}" ]; then\n'
            "        return 0\n"
            "    fi\n"
            '    output_dir="$DATA_PATH/data/out"\n'
            '    if [ ! -d "$output_dir" ]; then\n'
            '        echo "ERROR: Workflow output directory does not exist: $output_dir" >&2\n'
            "        return 2\n"
            "    fi\n"
            '    if [ -z "$(find "$output_dir" -mindepth 1 -print -quit)" ]; then\n'
            '        echo "ERROR: Workflow completed without producing files in $output_dir" >&2\n'
            "        return 2\n"
            "    fi\n"
            "}\n"
            "_nl_biomero_verify_outputs\n"
        )
        job_script = job_script.rstrip() + output_check

    return job_script
