#!/bin/bash

LOG_FILE="$HOME/git_svn_sync.log"
MAX_PARALLEL_JOBS=64 # cpu num 104
# LOCK_FILE="/tmp/git_svn_sync.lock"

# if [ -e "$LOCK_FILE" ]; then
#     log_message "Another instance is running, exit"
#     exit 1
# fi

# trap 'rm -f "$LOCK_FILE"' EXIT
# touch "$LOCK_FILE"

# Redirect output to log and standard out
exec > >(tee -a "$LOG_FILE") 2>&1

# Function to log messages with timestamps
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Function to manage conflicts
commit_conflicts()
local branch="$1"
    local message="$2"
    git add -A
    if ! git commit --allow-empty -m "[Conflict on $branch] $message"; then
        log_message "Failed to commit conflict state."
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
    if ! git ls-remote --heads "origin" "$branch" &>/dev/null; then
        git push -u origin $local_branch
    fi

    # Check for changes from GitLab to local branch
    local gitlab_updated=false
	if ! git diff --quiet "$remote_branch" "$local_branch"; then
        gitlab_updated=true
        gitlab_changes=$(git log --reverse --format="%H" $local_branch..$remote_branch)
        git checkout -f "$local_branch" && git merge --no-edit "$remote_branch" || return
    fi

    # Check for changes from SVN to the inter branch
    local svn_updated=false
    if ! git diff --quiet "refs/remotes/$svn_branch" "$inter_branch"; then
        svn_updated=true
        svn_changes=$(git log --reverse --format="%H" $inter_branch..$svn_branch)
        git checkout -f "$inter_branch" && git svn rebase || return
    fi

    # Handle GitLab updates merging into SVN branch
    if [ "$gitlab_updated" = true ]; then
        git checkout "$inter_branch"
        for commit in $gitlab_changes; do
            commit_message=$(git log --format=%B -n 1 "$commit")
            if ! git cherry-pick --strategy=recursive -X theirs "$commit"; then
                log_message "Cherry-pick conflict while applying $commit to $inter_branch. Committing conflicts..."
                commit_conflicts "$inter_branch" "$commit_message"
            fi
        done

        if git svn dcommit --add-author-from --use-log-author; then
            log_message "Successfully committed changes from $inter_branch to SVN."
        else
            log_message "Failed to dcommit changes from $inter_branch to SVN."
        fi
    fi

    # Handle SVN updates by merging them into the GitLab branch
    if [ "$svn_updated" = true ]; then
        git checkout "$local_branch"
        for commit in $svn_changes; do
            commit_message=$(git log --format=%B -n 1 "$commit")
            if ! git cherry-pick --strategy=recursive -X theirs "$commit"; then
                log_message "Failed to cherry-pick from $inter_branch to $local_branch. Committing conflicts..."
                commit_conflicts "$local_branch" "$commit_message"
            else
                git commit --amend -m "$commit_message"
            fi
        done
        if ! git push origin "$local_branch"; then
            log_message "Failed to push updates from $local_branch to GitLab."
        fi
    fi
}

# Function to sync all branches in a repository
sync_repository() {
    local repo_path="$1"

    cd "$repo_path" || { log_message "Failed to enter $repo_path"; return; }

    # Ensure repo is a git-svn repository
    if ! git rev-parse --is-inside-work-tree &>/dev/null || ! git config --get svn-remote.svn.url &>/dev/null; then
        log_message "Skipping $repo_path: Not a valid git-svn repository."
        return
    fi

    log_message "Processing repository at $repo_path"

    # Fetch all Git and SVN branches
    git fetch --all --prune || { log_message "Failed to fetch origin for $repo_path."; return; }
    git svn fetch --fetch-all || { log_message "Failed to fetch SVN for $repo_path."; return; }

    git branch -r | grep 'svn/' | while read -r remote_branch; do
        local branch
        branch=$(echo "$remote_branch" | sed 's|svn/||')
        sync_branch "$repo_path" "$branch"
	done
}

#echo expanded commands as they are executed (for debugging)
enable_expanded_output() {
    if [ $DEBUG ]; then
        set -o xtrace
        set +o verbose
    fi
}

#this is used to avoid outputting the repo URL, which may contain a secret token
disable_expanded_output() {
    if [ $DEBUG ]; then
        set +o xtrace
        set -o verbose
    fi
}

parse_args() {
    # Default values
    VERBOSE=false

    # Parse command-line options
    while getopts ":vD-" opt; do
    case ${opt} in
        v )
        VERBOSE=true
        ;;
        D )
        DEBUG=true
        echo "DEBUG $DEBUG"
        ;;
        - )
            case "${OPTARG}" in
                debug)
                    DEBUG=true
                    ;;
                *)
                    echo "Usage: $0 [-v] [-D|--debug] [path-to-git-dir]"
                    exit 1
					;;
            esac
            ;;
        \? )
        echo "Usage: $0 [-v|-D] [path-to-git-dir]"
        exit 1
        ;;
    esac
    done

    # Shift off the options
    shift $((OPTIND -1))
	if [ "$#" -gt 0 ]; then
        BASE_DIR="$1"
    else
        BASE_DIR="$(pwd)"
    fi
    # Validate BASE_DIR
    if [ ! -d "$BASE_DIR" ]; then
        echo "Error: '$BASE_DIR' is not a valid directory."
        exit 1
    fi
}

main() {
    parse_args "$@"
    enable_expanded_output

    # Export functions for parallel execution
    export -f sync_branch sync_repository log_message commit_conflicts enable_expanded_output disable_expanded_output DEBUG

    # Find all valid repositories and execute sync_repository for each
    find "$BASE_DIR" -type d -name ".git" -exec dirname {} \; | \
        xargs -n 1 -P "$MAX_PARALLEL_JOBS" bash -c 'DEBUG='"$DEBUG"' enable_expanded_output; sync_repository "$@"' _

    disable_expanded_output
	return 0
}

main "$@"