// cetex.dev — meniu „Projektai ▾“ Homepage tab'ų juostoje.
//
// Homepage tab'ai neturi išskleidžiamų meniu, todėl visi tab'ai, kurių nėra MAIN_TABS,
// laikomi projektais: jų mygtukai paslepiami, o juostoje lieka vienas „Projektai ▾“.
// Pasirinkus projektą paspaudžiamas paslėptas Homepage tab'o mygtukas — URL (#pickzy),
// aktyvus tab'as ir turinys lieka Homepage'o rankose.
//
// Naujas projektas: grupė services.yaml + layout įrašas settings.yaml; šito failo liesti nereikia.
// Jei Homepage pakeis tab'ų DOM (#myTab > li > button[role=tab]), meniu tiesiog neatsiras ir
// projektai bus matomi kaip paprasti tab'ai — niekas nesulūžta. Atnaujinus Homepage — patikrink.
(() => {
  "use strict";

  const MAIN_TABS = ["Serveris", "Įrankiai", "Nuorodos"];
  const LABEL = "Projektai";

  const tabList = () => document.getElementById("myTab");
  const tabButtons = (list) => [...list.querySelectorAll(':scope > li > button[role="tab"]')];
  const name = (button) => button.textContent.trim();
  const isProject = (button) => !MAIN_TABS.includes(name(button));

  function close(root) {
    root.querySelector(".cetex-projects-panel").hidden = true;
    root.querySelector(".cetex-projects-button").setAttribute("aria-expanded", "false");
  }

  function mount(list, firstProject, mainTab) {
    const root = document.createElement("li");
    // Look like a Homepage tab item: borrow a main tab's <li> classes (never a hidden project's).
    root.className = "cetex-projects " + (mainTab ? mainTab.parentElement.className : "");
    root.setAttribute("role", "presentation");

    const button = document.createElement("button");
    button.type = "button";
    button.className = "cetex-projects-button";
    button.setAttribute("aria-haspopup", "true");
    button.setAttribute("aria-expanded", "false");

    const panel = document.createElement("div");
    panel.className = "cetex-projects-panel";
    panel.hidden = true;

    button.addEventListener("click", (event) => {
      event.stopPropagation();
      const open = panel.hidden;
      panel.hidden = !open;
      button.setAttribute("aria-expanded", String(open));
    });
    document.addEventListener("click", (event) => {
      if (!root.contains(event.target)) close(root);
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape") close(root);
    });

    root.append(button, panel);
    list.insertBefore(root, firstProject.parentElement);
    return root;
  }

  function sync(list) {
    const buttons = tabButtons(list);
    const projects = buttons.filter(isProject);
    if (!projects.length) return;

    const mainTab = buttons.find((candidate) => !isProject(candidate));
    const root = list.querySelector(":scope > li.cetex-projects") || mount(list, projects[0], mainTab);

    for (const project of projects) project.parentElement.classList.add("cetex-project-tab");
    const button = root.querySelector(".cetex-projects-button");
    const panel = root.querySelector(".cetex-projects-panel");

    const names = projects.map(name).join("|");
    if (panel.dataset.names !== names) {
      panel.dataset.names = names;
      panel.replaceChildren(
        ...projects.map((project) => {
          const item = document.createElement("button");
          item.type = "button";
          item.className = "cetex-projects-item";
          item.textContent = name(project);
          item.addEventListener("click", () => {
            const target = tabButtons(tabList()).find((candidate) => name(candidate) === item.textContent);
            if (target) target.click();
            close(root);
          });
          return item;
        }),
      );
    }

    // Look like a Homepage tab: borrow the active or an inactive tab button's classes.
    const active = projects.find((project) => project.getAttribute("aria-selected") === "true");
    const lookAlike = active || buttons.find((candidate) => candidate.getAttribute("aria-selected") !== "true");
    const className = "cetex-projects-button " + (lookAlike ? lookAlike.className : "");
    if (button.className !== className) button.className = className;

    const text = (active ? `${LABEL}: ${name(active)}` : LABEL) + " ▾";
    if (button.textContent !== text) button.textContent = text;

    for (const item of panel.children) {
      item.classList.toggle("cetex-active", Boolean(active) && item.textContent === name(active));
    }
  }

  let queued = false;
  const resync = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      const list = tabList();
      if (list) sync(list);
    });
  };

  // Homepage renders client-side and re-renders on every data refresh: keep the menu in place.
  new MutationObserver(resync).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["aria-selected"],
  });
  resync();
})();
