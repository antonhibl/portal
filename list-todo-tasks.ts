#!/usr/bin/env bun
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";

// Run from the project root. Only the front matter is consumed, not the body.
async function isTodo(path: string) {
	const input = createReadStream(path, { encoding: "utf8" });
	const lines = createInterface({ input, crlfDelay: Infinity });
	let first = true;
	let frontmatter = "";
	try {
		for await (const line of lines) {
			if (first) {
				if (line.trim() !== "---") return false;
				first = false;
			} else if (line === "---" || line === "...") {
				const data = Bun.YAML.parse(frontmatter);
				return (
					data !== null &&
					typeof data === "object" &&
					"status" in data &&
					data.status === "todo"
				);
			} else {
				frontmatter += `${line}\n`;
			}
		}
		return false;
	} finally {
		lines.close();
		input.destroy();
	}
}

for await (const path of new Bun.Glob("tasks/**/*.md").scan({ dot: true })) {
	if (await isTodo(path)) console.log(path);
}
