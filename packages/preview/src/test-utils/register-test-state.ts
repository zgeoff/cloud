import { afterAll, afterEach, beforeAll } from 'bun:test';
import {
  commitStatuses,
  composeFiles,
  installationTokens,
  issueComments,
  pullRequestFiles,
  uninstalledRepos,
} from './constants.ts';
import { startSharedPreviewImpd, stopPreviewImpd } from './start-preview-impd.ts';

afterEach(() => {
  composeFiles.clear();
  pullRequestFiles.clear();
  uninstalledRepos.clear();

  issueComments.length = 0;
  commitStatuses.length = 0;
  installationTokens.length = 0;
});

// each file gets one impd that its tests share, started here so the start stays out of the first
// test's time limit, and stopped with the file
beforeAll(startSharedPreviewImpd);
afterAll(stopPreviewImpd);
