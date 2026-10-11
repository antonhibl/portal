// SPDX-License-Identifier: GPL-3.0-or-later
import html from "./about.html" with { type: "text" };

/** The about page, naming the Portal and Emacs versions Emacs passes in
 * PARAMS and this host's own Bun runtime. */
export function about(params: URLSearchParams): Response {
	const values: Record<string, string> = {
		portal: params.get("portal") || "unknown",
		emacs: params.get("emacs") || "unknown",
		bun: Bun.version,
	};
	const page = html.replace(/\{\{(\w+)\}\}/g, (_, name: string) =>
		Bun.escapeHTML(values[name] ?? ""),
	);
	return new Response(page, {
		headers: {
			"Content-Type": "text/html; charset=utf-8",
			"Content-Security-Policy":
				"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
		},
	});
}
