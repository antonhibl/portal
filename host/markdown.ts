// SPDX-License-Identifier: GPL-3.0-or-later
import { stat } from "node:fs/promises";
import { basename, isAbsolute } from "node:path";
import styles from "./markdown.css" with { type: "text" };

function page(title: string, body: string, status = 200): Response {
	return new Response(
		`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${Bun.escapeHTML(title)}</title>
  <style>${styles}</style>
</head>
<body><main>${body}</main></body>
</html>`,
		{
			status,
			headers: {
				"Content-Type": "text/html; charset=utf-8",
				// Markdown is a document, not executable application code.
				"Content-Security-Policy":
					"default-src 'none'; style-src 'unsafe-inline'; img-src https: http: data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
			},
		},
	);
}

function errorPage(message: string, status: number): Response {
	return page(
		"Markdown preview unavailable",
		`<h1>Cannot preview this file</h1><p>${Bun.escapeHTML(message)}</p>`,
		status,
	);
}

export async function markdown(path: string | null): Promise<Response> {
	if (!path || !isAbsolute(path) || path.includes("\0")) {
		return errorPage("Provide an absolute local file path.", 400);
	}
	try {
		if (!(await stat(path)).isFile()) {
			return errorPage("Choose a regular file.", 400);
		}
		const source = await Bun.file(path).text();
		const body = Bun.markdown.html(source, {
			tables: true,
			tasklists: true,
			strikethrough: true,
			headings: { ids: true },
			noHtmlBlocks: true,
			noHtmlSpans: true,
		});
		return page(basename(path), body);
	} catch (error) {
		const code = (error as NodeJS.ErrnoException).code;
		if (code === "ENOENT" || code === "ENOTDIR") {
			return errorPage("The file could not be found.", 404);
		}
		if (code === "EACCES" || code === "EPERM") {
			return errorPage("The file is not readable.", 403);
		}
		console.error("Markdown preview failed:", error);
		return errorPage("The file could not be rendered.", 500);
	}
}
