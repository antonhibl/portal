// SPDX-License-Identifier: GPL-3.0-or-later

/** The app host's request/reply connection to its parent Emacs. View contexts
 * are registered by Emacs, never by HTTP clients. No native state lives here. */
export class HostActions {
	private contexts = new Map<string, Record<string, unknown>>();
	private pending = new Map<
		string,
		{
			context: string;
			finish: (error?: string, value?: unknown) => void;
		}
	>();

	constructor(private send: (record: object) => void) {}

	context(id: string | null): Record<string, unknown> | undefined {
		return id ? this.contexts.get(id) : undefined;
	}

	receive(record: Record<string, unknown>) {
		if (typeof record.id !== "string") throw new Error("Missing record ID");
		switch (record.type) {
			case "context":
				if (!record.properties || typeof record.properties !== "object")
					throw new Error("Invalid context");
				this.contexts.set(
					record.id,
					record.properties as Record<string, unknown>,
				);
				break;
			case "forget":
				this.contexts.delete(record.id);
				for (const request of this.pending.values()) {
					if (request.context === record.id)
						request.finish("The originating Portal view has closed.");
				}
				break;
			case "result":
				this.pending
					.get(record.id)
					?.finish(
						typeof record.error === "string" ? record.error : undefined,
						record.value,
					);
				break;
			default:
				throw new Error("Unknown parent record");
		}
	}

	request(context: string, operation: string, args: object): Promise<unknown> {
		if (!this.contexts.has(context))
			return Promise.reject(
				new Error("Reload this Portal view before trying again."),
			);
		const id = crypto.randomUUID();
		const deadline = Date.now() + 15_000;
		return new Promise((resolve, reject) => {
			const timer = setTimeout(
				() =>
					finish(
						"The action timed out; it may already have run. Check before trying again.",
					),
				15_000,
			);
			const finish = (error?: string, value?: unknown) => {
				clearTimeout(timer);
				this.pending.delete(id);
				if (error) reject(new Error(error));
				else resolve(value);
			};
			this.pending.set(id, { context, finish });
			this.send({
				type: "request",
				id,
				context,
				operation,
				arguments: args,
				deadline,
			});
		});
	}
}
