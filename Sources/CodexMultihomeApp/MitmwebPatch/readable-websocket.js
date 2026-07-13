(() => {
    const rawMessages = new WeakMap();
    let readable = true;
    let mutationPending = false;

    function formatMessage(pre) {
        if (!rawMessages.has(pre)) rawMessages.set(pre, pre.textContent || "");
        const raw = rawMessages.get(pre);
        if (!readable) {
            if (pre.textContent !== raw) pre.textContent = raw;
            return;
        }
        try {
            const formatted = JSON.stringify(JSON.parse(raw), null, 2);
            if (pre.textContent !== formatted) pre.textContent = formatted;
        } catch (_) {
            // Binary and non-JSON WebSocket messages retain their original view.
        }
    }

    function enhanceWebSocketPane() {
        const pane = document.querySelector("section.websocket");
        if (!pane) return;
        pane.classList.add("homeport-readable-websocket");

        let toolbar = pane.querySelector(".homeport-websocket-toolbar");
        if (!toolbar) {
            toolbar = document.createElement("div");
            toolbar.className = "homeport-websocket-toolbar";
            const toggle = document.createElement("button");
            const updateToggle = () => {
                toggle.textContent = `Readable JSON: ${readable ? "On" : "Off"}`;
                toggle.setAttribute("aria-pressed", String(readable));
            };
            toggle.addEventListener("click", () => {
                readable = !readable;
                updateToggle();
                pane.querySelectorAll("pre").forEach(formatMessage);
            });
            updateToggle();

            const expand = document.createElement("button");
            expand.textContent = "Expand all";
            expand.addEventListener("click", () => {
                const shouldExpand = !pane.classList.contains("homeport-all-expanded");
                pane.classList.toggle("homeport-all-expanded", shouldExpand);
                pane.querySelectorAll("pre").forEach(pre => pre.classList.toggle("homeport-expanded", shouldExpand));
                expand.textContent = shouldExpand ? "Collapse all" : "Expand all";
            });

            const hint = document.createElement("span");
            hint.className = "homeport-hint";
            hint.textContent = "Click a message to expand it.";
            toolbar.append(toggle, expand, hint);
            const content = pane.querySelector(".contentview") || pane;
            content.prepend(toolbar);
        }

        pane.querySelectorAll("pre").forEach(pre => {
            formatMessage(pre);
            if (pre.dataset.homeportReadableBound !== "true") {
                pre.dataset.homeportReadableBound = "true";
                pre.addEventListener("click", () => pre.classList.toggle("homeport-expanded"));
            }
        });
    }

    const observer = new MutationObserver(() => {
        if (mutationPending) return;
        mutationPending = true;
        requestAnimationFrame(() => {
            mutationPending = false;
            enhanceWebSocketPane();
        });
    });
    observer.observe(document.documentElement, {childList: true, subtree: true});
    enhanceWebSocketPane();
})();
