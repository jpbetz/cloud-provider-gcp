#!/usr/bin/env bash

# Copyright 2015 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Based on https://github.com/kubernetes/kubernetes/blob/master/hack/cherry_pick_pull.sh
#
# To see everything that has changed:
# diff -r ../k8s/src/k8s.io/kubernetes/cluster cluster

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"
REBASEMAGIC="${REPO_ROOT}/.git/rebase-apply"
UPSTREAM_REMOTE=${UPSTREAM_REMOTE:-origin}
FORK_REMOTE=${FORK_REMOTE:-origin}
MAIN_REPO_ORG=${MAIN_REPO_ORG:-$(git remote get-url "$UPSTREAM_REMOTE" | awk '{gsub(/http[s]:\/\/|git@/,"")}1' | awk -F'[@:./]' 'NR==1{print $3}')}
MAIN_REPO_NAME=${MAIN_REPO_NAME:-$(git remote get-url "$UPSTREAM_REMOTE" | awk '{gsub(/http[s]:\/\/|git@/,"")}1' | awk -F'[@:./]' 'NR==1{print $4}')}

if [[ -e "${REBASEMAGIC}" ]]; then
  echo "!!! 'git rebase' or 'git am' in progress. Clean up and try again."
  exit 1
fi

if [[ -z ${GITHUB_USER:-} ]]; then
  echo "Please export GITHUB_USER=<your-user> (or GH organization, if that's where your fork lives)"
  exit 1
fi

if ! command -v gh > /dev/null; then
  echo "Can't find 'gh' tool in PATH, please install from https://github.com/cli/cli"
  exit 1
fi

if [[ "$#" -lt 1 ]]; then
    echo "${0} <after hash>: cherry-pick /cluster directory changes newer than <after hash> as a new PR"
    echo
    exit 2
fi

# Checks if you are logged in. Will error/bail if you are not.
gh auth status

if git_status=$(git status --porcelain --untracked=no 2>/dev/null) && [[ -n "${git_status}" ]]; then
  echo "!!! Dirty tree. Clean up and try again."
  exit 1
fi

# TODO: use a temporary checkout of k8s/k8s?
KUBERETES_CLONE=../k8s/src/k8s.io/kubernetes # for testing

AFTER=$1

LATEST=$(git -C "${KUBERETES_CLONE}" log --pretty=format:"%h" -n 1)
NEWBRANCH="cluster-merge-${AFTER}-${LATEST}"
NEWBRANCHUNIQ="${NEWBRANCH}-$(date +%s)"
echo "+++ Creating local branch ${NEWBRANCHUNIQ}"
#git checkout -b "${NEWBRANCHUNIQ}"

HASHES=$(git -C "${KUBERETES_CLONE}" log --reverse --merges --pretty=format:"%h" "${AFTER}..${LATEST}" -- cluster)

for HASH in $HASHES; do
    echo "+++ git -C ${KUBERETES_CLONE} format-patch ${HASH}~..${HASH} --stdout -- cluster > /tmp/${HASH}.patch"
    git -C "${KUBERETES_CLONE}" format-patch "${HASH}~..${HASH}" --stdout -- cluster > /tmp/${HASH}.patch
    echo
    echo "+++ About to attempt merging ${HASH}. To reattempt:"
    echo "  $ git am --signoff /tmp/${HASH}.patch"
    echo
    git am --signoff "/tmp/${HASH}.patch" || {
	conflicts=false
	while unmerged=$(git status --porcelain | grep ^U) && [[ -n ${unmerged} ]] || [[ -e "${REBASEMAGIC}" ]]; do
	    # TODO: could run git apply --check --reverse here to see if the patch is already applied
	    conflicts=true
	    echo
	    echo "+++ Conflicts detected:"
	    echo
	    (git status --porcelain | grep ^U) || echo "!!! None. Check the above 'git am' output for additional informmation."
	    echo
	    echo "+++ Please resolve the conflicts in another window (and remember to 'git add / git am --continue')"
	    read -p "+++ Proceed (anything but 'y' aborts the merge)? [y/n] " -r
	    echo
	    if ! [[ "${REPLY}" =~ ^[yY]$ ]]; then
		echo "Aborting." >&2
		exit 1
	    fi
	done
	if [[ "${conflicts}" != "true" ]]; then
	    echo "!!! git am failed, likely because of an in-progress 'git am' or 'git rebase'"
	    exit 1
	fi
    }
    rm -f "/tmp/${HASH}.patch"
done

rel="$(basename "${NEWBRANCH}")"
echo "+++ Pushing new branch to GitHub at ${GITHUB_USER}:${NEWBRANCH}"
git push "${FORK_REMOTE}" -f "${NEWBRANCHUNIQ}:${NEWBRANCH}"
echo "+++ Creating a pull request on GitHub at ${GITHUB_USER}:${NEWBRANCH}"
gh pr create --title="Automated merge of /cluster directory ${AFTER}..${LATEST}" --head "${GITHUB_USER}:${NEWBRANCH}" --base "${rel}" --repo="${MAIN_REPO_ORG}/${MAIN_REPO_NAME}"
