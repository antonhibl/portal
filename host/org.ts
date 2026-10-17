// SPDX-License-Identifier: GPL-3.0-or-later
import { stat } from "node:fs/promises";
import { basename, isAbsolute } from "node:path";
import { pathToFileURL } from "node:url";
import { errorPage, localFile, page, rewriteLocalPaths } from "./markdown";

// Emacs exports an Org file to HTML, the body of a page, and writes it to a
// file of its own; this serves that file as a preview of the Org file.  Only
// Emacs can export Org, so a link to another local file, Org or not, becomes
// a file: URL, which the page hands to Emacs: Emacs previews another Org file
// itself, and visits any other.  Images load from this host, as in Markdown
// previews.

/** Where a link in the Org file at PATH goes, or null to leave it: every
 * local file, with its fragment, as a file: URL for Emacs. */
export function orgLinkTarget(href: string, path: string): string | null {
	const local = localFile(href, path);
	return local && pathToFileURL(local.file).href + local.hash;
}

function unavailable(message: string, status: number): Response {
	return errorPage(message, status, "Org preview unavailable");
}

/** The exported body at PATH, an HTML file, as a preview of the Org file
 * SOURCE, whose links and images it resolves relative to SOURCE. */
export async function org(
	path: string | null,
	source: string | null,
): Promise<Response> {
	if (
		!path ||
		!isAbsolute(path) ||
		path.includes("\0") ||
		!/\.html$/i.test(path) ||
		!source ||
		!isAbsolute(source) ||
		source.includes("\0")
	) {
		return unavailable(
			"Provide the absolute paths of an exported HTML file and its Org file.",
			400,
		);
	}
	try {
		if (!(await stat(path)).isFile()) {
			return unavailable("Choose a regular file.", 400);
		}
		const body = await Bun.file(path).text();
		return page(
			basename(source),
			rewriteLocalPaths(body, source, orgLinkTarget),
		);
	} catch (error) {
		const code = (error as NodeJS.ErrnoException).code;
		if (code === "ENOENT" || code === "ENOTDIR") {
			return unavailable("The exported file could not be found.", 404);
		}
		if (code === "EACCES" || code === "EPERM") {
			return unavailable("The exported file is not readable.", 403);
		}
		console.error("Org preview failed:", error);
		return unavailable("The exported file could not be shown.", 500);
	}
}
