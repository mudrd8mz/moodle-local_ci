#!/usr/bin/env bash
# This script adds some automatisms helping to manage the integration queues:
#  - candidates queue: issues awaiting from integration not yet in current.
#  - current queue: issues under current integration.
#
# The automatisms are as follow:
#  0) Add the "integration_held" (+ std. comment) to new features & improvements issue missing it @ candidates.
#  1) Move "important" issues from candidates to current.
#  2) Move issues away from the current queue:
#    2a) Before a date (last week), keep the current queue fed with issues when it's under a threshold.
#    2b) After a date (last week), add the "integration_held" (+ std.comment) to bug issues.
#
# The criteria to consider an issue "important" are:
#  1) It must be in the candidates queue, awating for integration.        |
#  2) It must not have the integration_held or security_held labels.      | => filter=14000
#  3) It must not have the "agreed_to_be_after_release" text in a comment.| => NOT filter = 21366
#  4) At least one of this is true:
#    a) The issue has a must-fix version.                                 | => filter = 21363
#    b) The issue has the mdlqa label.                                    | => labels IN (mdlqa)
#    c) The issue priority is critical or higher.                         | => priority IN (Critical, Blocker)
#    d) The issue is flagged as security issue.                           | => level IS NOT EMPTY
#    e) The issue belongs to some of these components:                    | => component IN (...)
#      - Privacy
#      - Automated functional tests (behat)
#      - Unit tests
#
# This job must be enabled only since freeze day to packaging day.
#
# Parameters:
#  jiraclicmd: fill execution path of the jira cli
#  jiraserver: jira server url we are going to connect to
#  jirauser: user that will perform the execution
#  jirapass: password of the user
#  datetoholdbugs: first date to change behavior from 2a - feed current to 2b - held bug issues. (YYY-MM-DD)
#  currentmin: optional, number of issue under which the current queue will be fed from the candidates one.
#  movemax: optional, max number of issue that will be moved from candidates to current when under currentmin.

# Let's go strict (exit on error)
set -e

# Verify everything is set
required="WORKSPACE jiraclicmd jiraserver jirauser jirapass datetoholdbugs"
for var in $required; do
    if [ -z "${!var}" ]; then
        echo "Error: ${var} environment variable is not defined. See the script comments."
        exit 1
    fi
done

# file where results will be sent
resultfile=$WORKSPACE/continuous_manage_queues.csv
echo -n > "${resultfile}"

# file where updated entries will be logged
logfile=$WORKSPACE/continuous_manage_queues.log

# Calculate some variables
mydir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
basereq="${jiraclicmd} --server ${jiraserver} --user ${jirauser} --password ${jirapass}"
BUILD_TIMESTAMP="$(date +'%Y-%m-%d_%H-%M-%S')"

# Set defaults
currentmin=${currentmin:-6}
movemax=${movemax:-3}

# Verify that $datetoholdbugs has a correct YYYY-MM-DD format
if [[ ! ${datetoholdbugs} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "ERROR: Incorrect YYYY-MM-DD format detected: ${datetoholdbugs}"
    exit 1
fi

# Decide if we are going to perform the behavior 2a) move to current
# or 2b) hold bugs, based on current date.
behavior2=
holddate=$(date -d "${datetoholdbugs}" +%Y%m%d)
nowdate=$(date +%Y%m%d)
if [ $nowdate -lt $holddate ]; then
    behavior2="move"
else
    behavior2="hold"
fi

# Note this could be done by one unique "runFromIssueList" action, but we are splitting
# the search and the update in order to log all the closed issues within jenkins ($logfile)

# 0) Add the "integration_held" (+ std. comment) to new features & improvements issue missing it @ candidates.

# Basically get all the issues in the candidates queue (filter=14000), that are not bug
# and that haven't received any comment with the standard unholding text (NOT filter = 22054)

# Get the list of issues.
${basereq} --action getIssueList \
           --search "filter=14000 \
                 AND type IN ('New Feature', Improvement) \
                 AND NOT filter = 22054" \
           --file "${resultfile}"

# Iterate over found issues and perform the actions with them.
for issue in $( sed -n 's/^"\(MDL-[0-9]*\)".*/\1/p' "${resultfile}" ); do
    echo "Processing ${issue}"
    # Add the integration_held label.
    ${basereq} --action addLabels \
               --issue ${issue} \
               --labels "integration_held"
    # Add the standard comment for held issues.
    comment='This issue has been sent to integration after the freeze.

If you want Moodle HQ to consider including it into the incoming major release please add the "{{unhold_requested}}" label, and post a comment here outlining good reasons why you think it should be considered for late integration into the next major release.'
    ${basereq} --action addComment \
               --issue ${issue} \
               --comment "${comment}"
    echo "$BUILD_NUMBER $BUILD_TIMESTAMP ${issue} integration_held added" >> "${logfile}"
done

# 1) Move "important" issues from candidates to current.

# Get the list of issues.
${basereq} --action getIssueList \
           --search "filter=14000
                 AND NOT filter = 21366
                 AND (
                   filter = 21363 OR
                   labels IN (mdlqa) OR
                   priority IN (Critical, Blocker) OR
                   level IS NOT EMPTY OR
                   component IN ('Privacy', 'Automated functional tests (behat)', 'Unit tests')
                 )" \
           --file "${resultfile}"

# Iterate over found issues and perform the actions with them.
for issue in $( sed -n 's/^"\(MDL-[0-9]*\)".*/\1/p' "${resultfile}" ); do
    echo "Processing ${issue}"
    # For fields available in the default screen, it's ok to use updateIssue or SetField, but in this case
    # we are setting some custom fields not available (on purpose) on that screen. So we have created a
    # global transition, only available to the bots, not transitioning but bringing access to all the fields
    # via special screen. So we'll ne using that global transition via progressIssue instead.
    # Also, there is one bug in the 4.4.x series, setting the destination as 0, leading to error in the
    # execution, so the form was hacked in the browser to store correct -1: https://jira.atlassian.com/browse/JRA-25002
    # Commented below, it's the "ideal" code. If some day JIRA changes that restriction we could stop using
    # that non-transitional transition and use normal update.
    #${basereq} --action updateIssue \
    #    --issue ${issue} \
    #    --custom "customfield_10110:,customfield_10210:,customfield_10211:Yes"
    ${basereq} --action progressIssue \
               --issue ${issue} \
               --step "CI Global Self-Transition" \
               --field "Currently in integration" --values "Yes" \
               --comment "Continuous queues manage: Moving to current because it's important" \
               --role "Integrators"
    echo "$BUILD_NUMBER $BUILD_TIMESTAMP ${issue} moved to current: important" >> "${logfile}"
done

#  2) Move issues away from the current queue:

#    2a) Before a date (last week), keep the current queue fed with issues when it's under a threshold.

if [[ "${behavior2}" == "move" ]]; then
    # Count the list of issues in the current queue. (We cannot use getIssueCount till bumping to Jira CLI 8.1, hence, old way)
    ${basereq} --action getIssueList \
               --search "project = MDL \
                     AND 'Currently in integration' IS NOT EMPTY \
                     AND status IN ('Waiting for integration review')" \
               --file "${resultfile}"

    # Iterate over found issues just to count them.
    counter=0
    for issue in $( sed -n 's/^"\(MDL-[0-9]*\)".*/\1/p' "${resultfile}" ); do
        counter=$((counter+1))
    done
    echo "$counter issues awaiting integration in current queue"

    # If there are < $currentmin issues, let's add up to $movemax issues from the candidates queue.
    if [[ "$counter" -lt "$currentmin" ]]; then
        # Get an ordered list of up to $movemax issues in the candidate queue.
        ${basereq} --action getIssueList \
                   --limit $movemax \
                   --search "filter=14000 \
                       ORDER BY 'Integration priority' DESC, \
                                priority DESC, \
                                votes DESC, \
                                'Last comment date' ASC" \
                   --file "${resultfile}"

        # Iterate over found issues, moving them to the current queue.
        for issue in $( sed -n 's/^"\(MDL-[0-9]*\)".*/\1/p' "${resultfile}" ); do
            echo "Processing ${issue}"
            # For fields available in the default screen, it's ok to use updateIssue or SetField, but in this case
            # we are setting some custom fields not available (on purpose) on that screen. So we have created a
            # global transition, only available to the bots, not transitioning but bringing access to all the fields
            # via special screen. So we'll ne using that global transition via progressIssue instead.
            # Also, there is one bug in the 4.4.x series, setting the destination as 0, leading to error in the
            # execution, so the form was hacked in the browser to store correct -1: https://jira.atlassian.com/browse/JRA-25002
            # Commented below, it's the "ideal" code. If some day JIRA changes that restriction we could stop using
            # that non-transitional transition and use normal update.
            #${basereq} --action updateIssue \
            #    --issue ${issue} \
            #    --custom "customfield_10110:,customfield_10210:,customfield_10211:Yes"
            ${basereq} --action progressIssue \
                       --issue ${issue} \
                       --step "CI Global Self-Transition" \
                       --field "Currently in integration" --values "Yes" \
                       --comment "Continuous queues manage: Moving to current given we are below the threshold ($currentmin)" \
                       --role "Integrators"
            echo "$BUILD_NUMBER $BUILD_TIMESTAMP ${issue} moved to current: threshold (before ${datetoholdbugs})" >> "${logfile}"
        done
    fi
fi

#    2b) After a date (last week), add the "integration_held" (+ std.comment) to bug issues.

if [[ "${behavior2}" == "hold" ]]; then
    # Get the list of issues in the candidates queue. All them will be held with last week comment.
    ${basereq} --action getIssueList \
               --search "filter=14000" \
               --file "${resultfile}"

    # Iterate over found issues, moving them to the current queue.
    for issue in $( sed -n 's/^"\(MDL-[0-9]*\)".*/\1/p' "${resultfile}" ); do
        echo "Processing ${issue}"
        # Add the integration_held label.
        ${basereq} --action addLabels \
                   --issue ${issue} \
                   --labels "integration_held"
        # Add the standard comment for held issues the last week.
        comment='We are currently in the final week before release ( https://docs.moodle.org/dev/Integration_Review#During_continuous_integration.2FFreeze.2FQA_period ) so this issue is being held until after release. Thanks for your patience!'
        ${basereq} --action addComment \
                   --issue ${issue} \
                   --comment "${comment}"
        echo "$BUILD_NUMBER $BUILD_TIMESTAMP ${issue} integration_held added (since ${datetoholdbugs})" >> "${logfile}"
    done
fi

# Remove the resultfile. We don't want to disclose those details.
rm -fr "${resultfile}"
