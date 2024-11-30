#!/bin/bash
# Author: biopuppet <biopuppet@outlook.com>
# Date:   2024/11/29
# Description:
#   It gets in the specified git-svn repo to sync changes between GitLab repo 
# and SVN repo. It will cherry-pick every new *merge commit* to the SVN side
# at every branch-to-sync 1 by 1, and cherry-pick every *new revision* of SVN
# repo to the other side. If it detects multiple git-svn repos, it'll sync
# them concurrently.
# Note:
#   This script does not support revert* operations and it doesn't intend to.

LOG_FILE="$HOME/git_svn_sync.log"
MAX_PARALLEL_JOBS=64 # cpu num 104

# Redirect output to log and standard out
exec > >(tee -a "$LOG_FILE") 2>&1

# Function to log messages with timestamps
log() {
    echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] [$2] $1";
}
log_info()      { log "$1" "INFO"; }
log_success()   { log "$1" "SUCCESS"; }
log_error()     { log "$1" "ERROR"; }
log_warn()      { log "$1" "WARNING"; }
log_debug()     { log "$1" "DEBUG"; }

# Function to manage conflicts
commit_conflicts() {
    local branch="$1"
    local commit="$2"
    local message="$3"
    git add -A
    if ! git cherry-pick --continue -m 1 "[Conflict on $branch $commit] $message"; then
        git cherry-pick --skip
        log_warn "Skipping cherry-pick due to empty changes."
    fi
}

# Function to sync a single branch
sync_branch() {
    local repo_path="$1"
    local branch="$2"
    local svn_branch="svn/$branch"
    local inter_branch="inter/$branch"
    local local_branch="$branch"
    local remote_branch="origin/$branch"
    local gitlab_changes=""
    local svn_changes=""

    # Ensure local inter branch
    git show-ref --verify --quiet "refs/heads/$inter_branch" || git branch $inter_branch $svn_branch || return

    # Ensure local gitlab branch exists
    git show-ref --verify --quiet "refs/heads/$branch" || git branch $local_branch $inter_branch || return

    # Ensure remote gitlab branch exists
    if ! git ls-remote --heads "origin" "$branch" | grep -q "$branch"; then
        git push -u origin $local_branch
    fi

    # Only record gitlab merge commits in reverse order!
    gitlab_changes="$(git rev-list --merges --reverse $remote_branch ^$local_branch)"
    svn_changes="$(git rev-list --reverse $svn_branch ^$inter_branch)"

    # Check for changes from GitLab to local branch
    if [ -n "$gitlab_changes"} ]; then
        git checkout -f "$local_branch" && git merge --no-edit "$remote_branch" || return
    fi

    # Check for changes from SVN to the inter branch
    if [ -n "$svn_changes" ]; then
        git checkout -f "$inter_branch" && git svn rebase || return
    fi

    # Cherry-pick GitLab updates into SVN branch
    if [ -n "$gitlab_changes" ]; then
        git checkout -f "$inter_branch"
        for commit in $gitlab_changes; do
            if ! git cherry-pick --strategy=recursive -X theirs -m 1 "$commit"; then
                log_warn "Failed to cherry-pick $commit to $inter_branch. Committing conflicts..."
                commit_message=$(git log --format=%B -n 1 "$commit")
                commit_conflicts "$inter_branch" "$commit" "$commit_message"
            fi
        done

        if git svn dcommit --add-author-from --use-log-author; then
            log_info "Successfully committed changes from $inter_branch to SVN."
        else
            log_error "Failed to dcommit changes from $inter_branch to SVN."
        fi
    fi

    # Cherry-pick SVN updates into the GitLab branch
    if [ "$svn_updated" = true ]; then
        git checkout -f "$local_branch"
        for commit in $svn_changes; do
            commit_message=$(git log --format=%B -n 1 "$commit")
            if ! git cherry-pick --strategy=recursive -X ours -m 1 "$commit"; then
                log_warn "Cherry-pick conflict while applying $inter_branch to $local_branch. Committing conflicts..."
                commit_message=$(git log --format=%B -n 1 "$commit")
                commit_conflicts "$local_branch" "$commit" "$commit_message"
            fi
        done
        if ! git push origin "$local_branch"; then
            log_error "Failed to push updates from $local_branch to GitLab."
        fi
    fi
}

# Function to sync all branches in a repository
sync_repository() {
    local repo_path="$1"
    local combined_branches
    local git_branch_to_sync
    local svn_branch_to_sync
    local branch

    cd "$repo_path" || { log_message "Failed to enter $repo_path"; return; }

    # Ensure repo is a git-svn repository
    if ! git rev-parse --is-inside-work-tree &>/dev/null || ! git config --get svn-remote.svn.url &>/dev/null; then
        log_error "Skipping $repo_path: Not a valid git-svn repository."
        return
    fi

    # Remote origin check
    if ! git remote get-url origin &>/dev/null; then
        log_error "No remote origin set for repository at $repo_path. Skipping."
        return
    fi

    log_info "Processing repository at $repo_path"

    # Fetch all Git and SVN branches
    git_branch_to_sync=$(git fetch --all --prune 2>&1 | grep "\->" | awk '{print $(NF-2)}')
    svn_branch_to_sync=$(git svn fetch --fetch-all 2>&1 | grep "refs/remotes/" | awk -F"[()]" '{print $2}' | sed 's|refs/remotes/svn/||')

    if [ "$SYNC_ALL" = "true" ]; then
        combined_branches=$(git branch -r | grep 'svn/' | sed 's|svn/||')
    else
        combined_branches=$(echo -e "$git_branch_to_sync\n$svn_branch_to_sync" | uniq)
    fi

    for branch in $combined_branches; do
        local svn_br
        svn_br="refs/remotes/svn/$branch"
        # Only sync svn-tracked branches
        if git show-ref --quiet "$svn_br"; then
            log_debug "Syncing branch $branch:"
            sync_branch "$repo_path" "$branch"
        fi
    done
    log_info "Done processing repository at $repo_path"
}

#echo expanded commands as they are executed (for debugging)
enable_expanded_output() {
    if [ $DEBUG ]; then
        set -o xtrace
        set +o verbose
    fi
}

disable_expanded_output() {
    if [ $DEBUG ]; then
        set +o xtrace
        set -o verbose
    fi
}

parse_args() {
    # Default values
    SYNC_ALL=false
    # Parse command-line options
    while getopts ":aD" opt; do
    case ${opt} in
        a )
        SYNC_ALL=true
        ;;
        D )
        DEBUG=true
        ;;
        \? )
        echo "Usage: $0 [-a|-D] [path-to-git-dir]"
        exit 1
        ;;
    esac
    done

    # Shift off the options
    shift $((OPTIND -1))

    # Check if a directory argument is provided, otherwise use the current directory
    BASE_DIR="${1:-$(pwd)}"

    # Validate BASE_DIR
    if [ ! -d "$BASE_DIR" ]; then
        log_error "'$BASE_DIR' is not a valid directory."
        exit 1
    fi
}

main() {
    parse_args "$@"
    enable_expanded_output

    # Export functions for parallel execution
    export -f sync_branch sync_repository commit_conflicts enable_expanded_output disable_expanded_output log log_debug log_info log_warn log_success log_error
    export DEBUG SYNC_ALL 

    # Find all valid repositories and execute sync_repository for each
    find "$BASE_DIR" -type d -name ".git" -exec dirname {} \; | \
        xargs -n 1 -P "$MAX_PARALLEL_JOBS" bash -c 'enable_expanded_output; sync_repository "$@"' _

    disable_expanded_output
    return 0
}

main "$@"
