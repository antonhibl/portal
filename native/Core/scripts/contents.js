// SPDX-License-Identifier: GPL-3.0-or-later
// A toolbar's table of contents and find count (portal.h): portalToolbar in
// this script's world, and a report of the number of headings whenever it
// changes.
(report) => {
	let panel;
	const headings = () =>
		[...document.querySelectorAll("h1,h2,h3,h4,h5,h6")].filter(
			(h) => !panel?.contains(h),
		);
	globalThis.portalToolbar = {
		toc(open) {
			const items = headings();
			if (!panel) {
				panel = document.createElement("nav");
				panel.setAttribute("aria-label", "Table of contents");
				panel.style.cssText =
					"box-sizing:border-box;position:sticky;top:0;float:left;width: min(240px,35%);max-height:100vh;overflow:auto;padding:16px;font:13px/1.6 system-ui;background:Canvas;color:CanvasText;border-right:1px solid GrayText";
				document.body.prepend(panel);
			}
			panel.replaceChildren();
			for (const h of items) {
				const link = document.createElement("a");
				link.textContent = h.textContent;
				link.href = "#";
				link.style.cssText = `display:block;color:inherit;margin-left:${(Number(h.tagName[1]) - 1) * 10}px`;
				link.onclick = (event) => {
					event.preventDefault();
					h.scrollIntoView({ block: "start", behavior: "smooth" });
				};
				panel.append(link);
			}
			panel.hidden = !open || !items.length;
			return items.length;
		},
		count(query) {
			if (!query) return 0;
			const text = document.body.innerText.toLocaleLowerCase();
			const needle = query.toLocaleLowerCase();
			let count = 0;
			let index = 0;
			while ((index = text.indexOf(needle, index)) !== -1) {
				count++;
				index += needle.length;
			}
			return count;
		},
	};
	let previous = -1;
	new MutationObserver(() => {
		const count = headings().length;
		if (count !== previous) {
			previous = count;
			report(count);
		}
	}).observe(document.body, { childList: true, subtree: true });
	report(headings().length);
}
