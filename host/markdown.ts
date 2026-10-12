// SPDX-License-Identifier: GPL-3.0-or-later
import { stat } from "node:fs/promises";
import { basename, isAbsolute } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import styles from "./markdown.css" with { type: "text" };

function page(title: string, body: string, status = 200): Response {
	return new Response(
		`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${Bun.escapeHTML(title)}</title>
  <link rel="icon" type="image/png" sizes="32x32" href="assets/portal-32.png">
  <link rel="icon" type="image/png" sizes="64x64" href="assets/portal-64.png">
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

// The extensions `portal-render-markdown' accepts, in any case.
const markdownFile = /\.(?:md|markdown|mdown|mkd|mkdn)$/i;

// HTMLRewriter reads attribute values as written, and Bun writes these.
const entities: Record<string, string> = {
	"&amp;": "&",
	"&lt;": "<",
	"&gt;": ">",
	"&quot;": '"',
};

/** Where a link in the Markdown file at PATH should go, or null to leave it.
 * Local Markdown files open in this preview, as a URL relative to it; other
 * local files and directories become file: URLs, which Emacs visits. */
export function linkTarget(href: string, path: string): string | null {
	if (href.startsWith("#") || href.startsWith("//")) return null;
	if (/^[a-z][a-z\d+.-]*:/i.test(href) && !/^file:/i.test(href)) return null;
	let url: URL;
	let file: string;
	try {
		url = new URL(href, pathToFileURL(path));
		if (url.protocol !== "file:") return null;
		file = fileURLToPath(url);
	} catch {
		return null;
	}
	if (markdownFile.test(file)) {
		return `markdown?path=${encodeURIComponent(file)}${url.hash}`;
	}
	return pathToFileURL(file).href + url.hash;
}

function rewriteLinks(html: string, path: string): string {
	return new HTMLRewriter()
		.on("a[href]", {
			element(link) {
				const href = (link.getAttribute("href") ?? "").replace(
					/&(?:amp|lt|gt|quot);/g,
					(entity) => entities[entity] ?? entity,
				);
				const target = linkTarget(href, path);
				// HTMLRewriter escapes only quotes in the values it writes.
				if (target !== null)
					link.setAttribute("href", target.replaceAll("&", "&amp;"));
			},
		})
		.transform(html);
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
		return page(basename(path), rewriteLinks(body, path));
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
