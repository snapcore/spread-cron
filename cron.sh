#!/bin/bash

INIT_DIR="$(pwd)"
BASE_DIR="$SNAP_COMMON/spread-cron"
STEP_TIME=600
RECOVER_TIME=60
FINAL_TIME=0
INITIAL_TIME=0
CLEAN_ITERS=12

record_new_value(){
    message=$1
    new_value=$2
    git commit --allow-empty -m "$message ($new_value)"
    git push
}

check(){
    . "$BASE_DIR"/options

    if [ -z "$pattern_extractor" -o -z "$message" ]; then
        echo "Required fields pattern_extractor and message not found in ../options"
        exit 1
    fi

    new_value=$(eval "$pattern_extractor" | tr -d '\r')
    if [ -z "$new_value" ] || [ "$new_value" = "null" ]; then
        echo "pattern extractor $pattern_extractor could not extract anything"
        exit 1
    fi

    if [ "$manual" = "true" ]; then
        echo "Manual branches are skipped"
        return
    fi

    total_commits=$(git rev-list --count HEAD)
    n=0
    while [ $n -lt $total_commits ]; do
        log_entry=$(git log HEAD~${n} --pretty=%B | head -1)
        if echo "$log_entry" | grep "^$message" ; then
            old_value=$( echo "$log_entry" | sed -e "s|$message (\(.*\))|\1|")
            if [ "$new_value" != "$old_value" ]; then
                record_new_value "$message" "$new_value"
            fi
            exit 0
        fi
        n=$((n+1))
    done
    # no previous recorded value found
    record_new_value "$message" "$new_value"
}

if [ -n "$HTTPS_PROXY" ] && ! git config -l | grep -q https.proxy; then
    echo "Setting https proxy for git"
    git config --global https.proxy "$HTTPS_PROXY"
fi

if [ -n "$HTTP_PROXY" ] && ! git config -l | grep -q http.proxy; then
    echo "Setting http proxy for git"
    git config --global http.proxy "$HTTP_PROXY"
fi

iter=0
while true; do
    echo "Moving to init dir"
    cd "$INIT_DIR"

    iter=$((iter+1))
    echo "Iteration $iter started"

    # run checker on each branch
    if [ ! -f "$SNAP_COMMON/git-credentials" ]; then
        echo "No credentials file found, please run 'snap set spread-cron username=<username> password=<password>' with valid credentials of a github user with push priveleges for the snapcore/spread-cron repository."
    else
        if [ ! -d "$BASE_DIR" ]; then
            git clone https://github.com/snapcore/spread-cron.git "$BASE_DIR"
        fi
        if [ ! -d "$BASE_DIR" ]; then
            sleep "$RECOVER_TIME"
            continue
        fi
        echo "Moving to base dir"
        cd "$BASE_DIR"

        INITIAL_TIME=$SECONDS
        git remote prune origin
        for remote in $(git branch -r); do
            if [ "$remote" != "origin/HEAD" ] && [ "$remote" != "origin/master" ] && [ "$remote" != "->" ]; then
                branch="${remote#origin/}"
                git branch --track "$branch" "$remote";
                git checkout "$branch"
                git reset --hard "$remote"
                ( check )
            fi
        done
        FINAL_TIME=$SECONDS
    fi

    # Clean local repository after $CLEAN_ITERS iterations
    # This is done to avoid races that could happen when there are remote changes
    if [ "$iter" -ge "$CLEAN_ITERS" ]; then
        echo "Cleaning local repository"
        iter=0
        rm -rf "$BASE_DIR"
    fi

    # Wait for next iteration
    echo "Waiting for next iteration $((STEP_TIME - FINAL_TIME + INITIAL_TIME)) seconds"
    sleep $((STEP_TIME - FINAL_TIME + INITIAL_TIME))
done
