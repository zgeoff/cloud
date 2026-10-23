// Alertmanager's config holds no secret but a file path, and a message reads a file only through a
// template, so the user to mention reaches it as a template file in the webhook's Secret.
export function renderMentionTemplate(userID: string): string {
  return `{{ define "discord.mention" }}<@${userID}>{{ end }}\n`;
}
