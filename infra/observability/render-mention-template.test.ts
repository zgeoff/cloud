import { expect, test } from 'bun:test';
import { renderMentionTemplate } from './render-mention-template.ts';

test('it defines the Discord mention of the user as an Alertmanager template', () => {
  expect(renderMentionTemplate('100000000000000001')).toBe(
    '{{ define "discord.mention" }}<@100000000000000001>{{ end }}\n',
  );
});
