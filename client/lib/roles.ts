export type AppRole = "guest" | "manager" | "worker";

export const isWorkerRole = (role: string | null | undefined): boolean => role === "worker";

export const WORKER_ROLE_VALUES = ["worker"];
