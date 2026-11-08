#!/bin/sh
# Pull della configurazione da GitHub (deploy key in sola lettura), lanciato da Claude via shell_command.
# Gira nel container come root: al termine riporta la proprietà dei file tracciati e di .git all'utente 1000.
cd /config || exit 1
export GIT_SSH_COMMAND="ssh -i /config/.ssh/ha_deploy_ro -o IdentitiesOnly=yes -o UserKnownHostsFile=/config/.ssh/known_hosts"
git -c safe.directory=/config pull --ff-only
rc=$?
{ git -c safe.directory=/config ls-files | cut -d/ -f1; echo .git; } | sort -u | xargs chown -R 1000:1000
exit $rc
