import type { Request, Response } from "express";
import { createServer } from "../server/index.js";

const app = createServer();

export default (request: Request, response: Response) => {
  const path = request.query.path;
  const pathSegments = Array.isArray(path) ? path : typeof path === "string" ? [path] : [];
  if (pathSegments.length === 0) return response.status(404).json({ error: "API endpoint not found" });

  const requestUrl = new URL(request.url || "/", "https://vercel.invalid");
  requestUrl.searchParams.delete("path");
  requestUrl.pathname = `/api/${pathSegments.join("/").split("/").map(encodeURIComponent).join("/")}`;
  request.url = `${requestUrl.pathname}${requestUrl.search}`;
  return app(request, response);
};
