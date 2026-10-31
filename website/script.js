const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const animalImages = [...document.querySelectorAll('[data-frame-sequence="cat"]')];
if (animalImages.length && !reducedMotion) {
  const firstFrame = new URL(animalImages[0].getAttribute("src"), document.baseURI).href;
  const frameUrls = Array.from({ length: 5 }, (_, index) => firstFrame.replace(/0\.png$/, `${index}.png`));
  let frameIndex = 0;
  let timer;

  const syncPlayback = () => {
    if (document.hidden) {
      clearInterval(timer);
      timer = undefined;
    } else if (!timer) {
      timer = setInterval(() => {
        frameIndex = (frameIndex + 1) % frameUrls.length;
        animalImages.forEach((image) => { image.src = frameUrls[frameIndex]; });
      }, 125);
    }
  };

  Promise.all(frameUrls.map((src) => new Promise((resolve, reject) => {
    const frame = new Image();
    frame.onload = resolve;
    frame.onerror = reject;
    frame.src = src;
  }))).then(() => {
    syncPlayback();
    document.addEventListener("visibilitychange", syncPlayback);
  }).catch(() => {});
}

if (!reducedMotion && "IntersectionObserver" in window) {
  const revealObserver = new IntersectionObserver((entries, observer) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      }
    }
  }, { threshold: 0.1 });
  document.querySelectorAll(".reveal").forEach((element) => revealObserver.observe(element));
} else {
  document.querySelectorAll(".reveal").forEach((element) => element.classList.add("is-visible"));
}

const features = [...document.querySelectorAll(".feature-item")];
const slides = [...document.querySelectorAll(".feature-slide")];
const counter = document.querySelector(".caption-index");

if (features.length === slides.length && "IntersectionObserver" in window) {
  const featureObserver = new IntersectionObserver((entries) => {
    const visible = entries
      .filter((entry) => entry.isIntersecting)
      .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
    if (!visible) return;
    const index = Number(visible.target.dataset.feature);
    features.forEach((item, i) => item.classList.toggle("is-active", i === index));
    slides.forEach((item, i) => item.classList.toggle("is-active", i === index));
    if (counter) counter.textContent = `0${index + 1} / 0${features.length}`;
  }, { rootMargin: "-25% 0px -25% 0px", threshold: [0, 0.25, 0.5, 0.75] });
  features.forEach((element) => featureObserver.observe(element));
}

const hero = document.querySelector(".hero");
const heroHeading = hero?.querySelector(".hero-heading");
const heroStage = hero?.querySelector(".hero-stage");

if (hero && heroHeading && heroStage) {
  const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  let ticking = false;

  const updateHero = () => {
    ticking = false;
    if (motionQuery.matches) {
      heroHeading.style.transform = "";
      heroStage.style.transform = "";
      return;
    }

    const stageTop = heroStage.getBoundingClientRect().top + window.scrollY;
    const start = Math.max(stageTop - window.innerHeight * 0.85, 0);
    const distance = Math.max(Math.min(hero.offsetHeight * 0.45, window.innerHeight * 0.65), 300);
    const progress = Math.min(Math.max((window.scrollY - start) / distance, 0), 1);
    const mobile = window.innerWidth <= 760;
    const scale = (mobile ? 0.9 : 1.05) + (mobile ? 0.1 : -0.05) * progress;

    heroHeading.style.transform = `translateY(${-100 * progress}px)`;
    heroStage.style.transform = `rotateX(${20 * (1 - progress)}deg) scale(${scale})`;
  };

  const requestHeroUpdate = () => {
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(updateHero);
    }
  };

  window.addEventListener("scroll", requestHeroUpdate, { passive: true });
  window.addEventListener("resize", requestHeroUpdate);
  motionQuery.addEventListener?.("change", requestHeroUpdate);
  updateHero();
}
