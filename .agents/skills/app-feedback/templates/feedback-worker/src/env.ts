/** Bindings and settings from the Workers config and Worker secrets. */
export type WorkerEnv = {
  FEEDBACK_SENDER_LIMIT: { limit(options: { key: string }): Promise<{ success: boolean }> };
  DAILY_QUOTA: {
    idFromName(name: string): unknown;
    get(id: unknown): { fetch(input: string, init?: RequestInit): Promise<Response> };
  };
  GITHUB_REPOSITORY: string;
  DAILY_ISSUE_LIMIT?: string;
  /** Worker secrets registered by the provisioning tool; read only by github-app-auth.ts. */
  GITHUB_APP_ID?: string;
  GITHUB_APP_INSTALLATION_ID?: string;
  GITHUB_APP_SIGNING_PKCS8?: string;
};
