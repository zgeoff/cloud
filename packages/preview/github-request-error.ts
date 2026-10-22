export class GitHubRequestError extends Error {
  readonly status: number;

  readonly permanent: boolean;

  constructor(message: string, status: number, permanent: boolean) {
    super(message);

    this.name = 'GitHubRequestError';
    this.status = status;
    this.permanent = permanent;
  }
}
