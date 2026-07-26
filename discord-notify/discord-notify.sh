#!/usr/bin/env bash
# discord-notify - send the release-failure Discord notification, naming the
# failed job(s) (derived from the needs context) instead of "check the run".
#
# Env inputs:
#   DISCORD_WEBHOOKS comma-separated webhook URLs; empty = skip sending
#   REPO             github.repository
#   RUN_ID           github.run_id
#   REF_NAME         github.ref_name (the release tag)
#   ACTOR            github.actor
#   ENV_NAME         parsed release env (staging | prod); may be empty
#   NEEDS_JSON       toJSON(needs) of the calling job - used to find failed jobs
#   DRY_RUN          "true" = build and print the payload without sending
#
# Outputs (GITHUB_OUTPUT): title, failed_jobs

set -euo pipefail

GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
DRY_RUN="${DRY_RUN:-false}"
ENV_NAME="${ENV_NAME:-unknown}"

failed_jobs="$(printf '%s' "$NEEDS_JSON" | jq -r 'to_entries | map(select(.value.result == "failure") | .key) | join(", ")')"
guard_result="$(printf '%s' "$NEEDS_JSON" | jq -r '.guard.result // "none"')"

if [ "$guard_result" = "failure" ]; then
  title="Unauthorized prod release blocked"
  desc="Actor \`${ACTOR}\` is not permitted to push prod release tag \`${REF_NAME}\`. The pipeline refused to act on it."
else
  title="Release failed: ${REF_NAME}"
  if [ -n "$failed_jobs" ]; then
    desc="Failed job(s): \`${failed_jobs}\`. See the run log for details."
  else
    desc="The release pipeline failed for tag \`${REF_NAME}\`. See the run log for details."
  fi
fi

echo "title=$title" >> "$GITHUB_OUTPUT"
echo "failed_jobs=${failed_jobs:-none}" >> "$GITHUB_OUTPUT"

jq -n \
  --arg title "$title" \
  --arg desc "$desc" \
  --arg repo "$REPO" \
  --arg run_id "$RUN_ID" \
  --arg ref "$REF_NAME" \
  --arg env "$ENV_NAME" \
  --arg actor "$ACTOR" \
  --arg failed "${failed_jobs:-none}" \
  '{
    embeds: [{
      title: $title,
      url: "https://github.com/\($repo)/actions/runs/\($run_id)",
      description: $desc,
      color: 15158332,
      fields: [
        { name: "Tag",          value: "`\($ref)`",    inline: true },
        { name: "Env",          value: "`\($env)`",    inline: true },
        { name: "Actor",        value: "`\($actor)`",  inline: true },
        { name: "Failed job(s)", value: "`\($failed)`", inline: true }
      ]
    }],
    username: "GitHub Actions",
    avatar_url: "https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png"
  }' > payload.json

if [ "$DRY_RUN" = "true" ]; then
  echo "dry run - payload built but not sent:"
  cat payload.json
  exit 0
fi

if [ -z "${DISCORD_WEBHOOKS:-}" ]; then
  echo "no Discord webhook configured - skipping failure notification"
  exit 0
fi

sent=0
for url in $(printf '%s' "$DISCORD_WEBHOOKS" | tr ',' ' '); do
  curl -s -o /dev/null -w "discord webhook -> HTTP %{http_code}\n" -H "Content-Type: application/json" -d @payload.json "$url"
  sent=$((sent + 1))
done
echo "failure notification sent to ${sent} webhook(s): ${title}"
