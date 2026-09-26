// Широкие диаграммы Mermaid не сжимаются до нечитаемого размера: минимальный масштаб 0,7, дальше — горизонтальная прокрутка.
(function () {
  var MIN_SCALE = 0.7;
  function fix() {
    var svgs = document.querySelectorAll('code.language-mermaid svg');
    for (var k = 0; k < svgs.length; k++) {
      var svg = svgs[k];
      if (svg.getAttribute('data-sp-fixed')) continue;
      var vb = svg.viewBox && svg.viewBox.baseVal;
      var box = svg.closest('pre') || svg.parentElement;
      if (!vb || !vb.width || !box) continue;
      var avail = box.clientWidth;
      if (avail && vb.width * MIN_SCALE > avail) {
        svg.style.maxWidth = 'none';
        svg.style.width = Math.round(vb.width * MIN_SCALE) + 'px';
        box.style.overflowX = 'auto';
      }
      svg.setAttribute('data-sp-fixed', '1');
    }
  }
  function schedule() { [300, 1000, 2500].forEach(function (t) { setTimeout(fix, t); }); }
  if (document.readyState === 'complete') schedule(); else window.addEventListener('load', schedule);
})();
