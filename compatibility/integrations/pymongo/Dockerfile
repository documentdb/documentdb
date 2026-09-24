# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

FROM python:3.12-slim-bookworm@sha256:782412e85d0f0984994c290652577d4018aff08145c85b262bb63dc0c7522254

COPY wheels /wheels
COPY compatibility/integrations/pymongo/requirements.txt /requirements.txt
COPY integration-requirements.txt /integration-requirements.txt
RUN python -m pip install --no-index --find-links=/wheels \
    --report=/install-report.json --disable-pip-version-check \
    -r /integration-requirements.txt && useradd --create-home --uid 1000 runner
COPY compatibility /app/compatibility
WORKDIR /app
USER 1000:1000
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTEST_DISABLE_PLUGIN_AUTOLOAD=1
ENV COMPATIBILITY_ACTIVE=1
ENTRYPOINT ["python", "-m", "compatibility.client"]
