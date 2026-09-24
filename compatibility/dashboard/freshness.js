// Copyright (c) Microsoft Corporation.
// SPDX-License-Identifier: MIT

"use strict";

function updateFreshness(now) {
    for (const element of document.querySelectorAll("[data-compatibility-status]")) {
        const tested = Date.parse(element.dataset.conclusiveAt);
        const maximumAge = Number(element.dataset.freshnessDays) * 86400000;
        if (Number.isFinite(tested) && now - tested > maximumAge) {
            element.textContent = `Stale (last: ${element.dataset.previousState})`;
            element.className = "Stale";
        }
    }
}

updateFreshness(Date.now());
setInterval(() => updateFreshness(Date.now()), 60000);
