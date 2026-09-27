// SPDX-License-Identifier: GPL-3.0-or-later
// A hosted app's links to local files, which a page from the app host cannot
// follow: report the URL of each one the user clicks (portal.h).
(report) => {
	document.addEventListener(
		"click",
		(event) => {
			const link =
				event.target instanceof Element && event.target.closest("a[href]");
			if (
				!event.isTrusted ||
				event.button !== 0 ||
				!link ||
				link.protocol !== "file:"
			)
				return;
			event.preventDefault();
			report(link.href);
		},
		true,
	);
}
