#!/usr/bin/env bash

git clone --depth 1 --single-branch --branch "${BRANCH:-master}" "https://gitlab-ci-token:${CI_JOB_TOKEN}@gitlab.com/${GITLAB_USER}/ci-utils.git" ci-tmp
rsync -a ci-tmp/* ./ci-utils

# shellcheck disable=SC1091
source ./ci-utils/utils.sh

exit 1
