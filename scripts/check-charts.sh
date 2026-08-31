#!/bin/sh
set -eu

find charts -mindepth 2 -maxdepth 2 -name Chart.yaml -print | sort |
while IFS= read -r chart_file; do
  chart_dir=${chart_file%/Chart.yaml}
  chart_name=${chart_dir#charts/}

  test -f "${chart_dir}/values.schema.json" || {
    echo "${chart_name}: values.schema.json is required" >&2
    exit 1
  }

  helm lint --strict "${chart_dir}"
  helm template "${chart_name}" "${chart_dir}" |
    docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
      -strict \
      -summary \
      -ignore-missing-schemas

  chart_test="./scripts/test-${chart_name}-chart.sh"
  if test -x "${chart_test}"; then
    "${chart_test}"
  fi
done

if ! find charts -mindepth 2 -maxdepth 2 -name Chart.yaml -print -quit | grep -q .; then
  echo "No charts found; empty collection is valid."
fi
