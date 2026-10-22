export class GitHubRequestError extends Error {
  readonly status: number;

  // a retry of the same request gets the same refusal
  readonly permanent: boolean;

  constructor(message: string, status: number, permanent: boolean) {
    super(message);

    this.name = 'GitHubRequestError';
    this.status = status;
    this.permanent = permanent;
  }
}
