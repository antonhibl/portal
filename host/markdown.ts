// SPDX-License-Identifier: GPL-3.0-or-later
import { stat } from "node:fs/promises";
import { basename, isAbsolute } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import styles from "./markdown.css" with { type: "text" };

/** A page of Markdown styles and BODY. A document runs no code. An app page,
 * with SCRIPT, runs only that script, which may post to the app host. */
export function page(
	title: string,
	body: string,
	status = 200,
	{ css = "", script }: { css?: string; script?: string } = {},
): Response {
	const policy = script
		? `script-src 'sha256-${new Bun.CryptoHasher("sha256").update(script).digest("base64")}'; connect-src 'self'; form-action 'self'`
		: "form-action 'none'";
	return new Response(
		`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${Bun.escapeHTML(title)}</title>
  <style>${styles}${css}</style>${script ? `\n  <script>${script}</script>` : ""}
</head>
<body><main>${body}</main></body>
</html>`,
		{
			status,
			headers: {
				"Content-Type": "text/html; charset=utf-8",
				// A no-referrer POST has an opaque Origin in WebKit. Keep its
				// origin for same-origin actions, without sending paths outside.
				"Referrer-Policy": script ? "same-origin" : "no-referrer",
				"Content-Security-Policy": `default-src 'none'; style-src 'unsafe-inline'; img-src https: http: data:; ${policy}; base-uri 'none'; frame-ancestors 'none'`,
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

/** Markdown SOURCE as HTML. Raw HTML stays text, so a document runs no code. */
export function render(source: string): string {
	return Bun.markdown.html(source, {
		tables: true,
		tasklists: true,
		strikethrough: true,
		headings: { ids: true },
		noHtmlBlocks: true,
		noHtmlSpans: true,
	});
}

// The extensions `portal-preview-markdown' accepts, in any case.
const markdownFile = /\.(?:md|markdown|mdown|mkd|mkdn)$/i;

// HTMLRewriter reads attribute values as written, and Bun writes these.
const entities: Record<string, string> = {
	"&amp;": "&",
	"&lt;": "<",
	"&gt;": ">",
	"&quot;": '"',
};

/** The value of attribute NAME as Bun wrote it, with its entities decoded. */
export function attribute(element: HTMLRewriterTypes.Element, name: string) {
	return (element.getAttribute(name) ?? "").replace(
		/&(?:amp|lt|gt|quot);/g,
		(entity) => entities[entity] ?? entity,
	);
}

/** The local file or directory that HREF, in the Markdown file at PATH, names,
 * with its fragment; or null for a fragment alone or a non-file URL. */
export function localTarget(
	href: string,
	path: string,
): { file: string; hash: string } | null {
	if (href.startsWith("#") || href.startsWith("//")) return null;
	if (/^[a-z][a-z\d+.-]*:/i.test(href) && !/^file:/i.test(href)) return null;
	try {
		const url = new URL(href, pathToFileURL(path));
		if (url.protocol !== "file:") return null;
		return { file: fileURLToPath(url), hash: url.hash };
	} catch {
		return null;
	}
}

/** Where a link in the Markdown file at PATH should go, or null to leave it.
 * Local Markdown files open in this preview, as a URL relative to it; other
 * local files and directories become file: URLs, which Emacs visits. */
export function linkTarget(href: string, path: string): string | null {
	const target = localTarget(href, path);
	if (!target) return null;
	if (markdownFile.test(target.file)) {
		return `markdown?path=${encodeURIComponent(target.file)}${target.hash}`;
	}
	return pathToFileURL(target.file).href + target.hash;
}

function rewriteLinks(html: string, path: string): string {
	return new HTMLRewriter()
		.on("a[href]", {
			element(link) {
				const target = linkTarget(attribute(link, "href"), path);
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
		return page(basename(path), rewriteLinks(render(source), path));
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
