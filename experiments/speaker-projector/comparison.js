"use strict";
(async () => {
  const $ = id => document.getElementById(id);
  const response = await fetch("comparison-data.json");
  if (!response.ok) throw new Error("Could not load comparison data.");
  const data = await response.json();
  const rows = data.rows, palette = ["#2463b4", "#d96726", "#238266", "#a04899", "#b18b1e", "#5974a8", "#cc5261", "#55792e", "#8d62bd", "#4a7f88", "#747474"];
  let mode = "mds", selected = 0, pair = rows.length > 1 ? 1 : 0;
  let drawing = false, redraw = false;
  const plotText = value => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
  const clusters = [...new Set(rows.map(row => row.cluster))];
  const colors = new Map(clusters.map((cluster, i) => [cluster, cluster === "Saved reference" ? "#717b89" : palette[i % palette.length]]));
  function overlap(a, b) { return a.source === b.source && Math.max(a.start, b.start) < Math.min(a.end, b.end); }
  function option(row) { const item = document.createElement("option"); item.value = row.row; item.textContent = row.label; return item; }
  rows.forEach(row => { $("sampleSelect").append(option(row)); $("pairSelect").append(option(row)); });
  function metadata(row) {
    const role = row.role === "historical_reference" ? "Historical reference" : "Fresh replay";
    return `${role} · ${row.source} · ${row.start.toFixed(2)}–${row.end.toFixed(2)} s · ${row.trust.replaceAll("_", " ")}` + (row.representativeRank ? ` · Selected example ${row.representativeRank}` : "") + (row.referenceName ? ` · Reviewed reference: ${row.referenceName}` : "");
  }
  function audio(id, url) { if ($(id).getAttribute("src") !== url) { $(id).pause(); $(id).src = url; } }
  function inspect() {
    const a = rows[selected], b = rows[pair];
    $("sampleSelect").value = selected; $("pairSelect").value = pair;
    $("selectedTitle").textContent = a.label; $("selectedMeta").textContent = metadata(a);
    audio("selectedAudio", a.audio); audio("pairAudio", b.audio);
    $("pairScore").textContent = `Cosine ${data.cosine[selected][pair].toFixed(4)}`;
    $("pairMeta").textContent = `${b.label}. ${selected === pair ? "Same sample." : overlap(a, b) ? "Overlapping source audio — not independent evidence." : "No overlapping source audio."} ${metadata(b)}`;
    const nearest = rows.map((row, index) => index).filter(i => i !== selected && (!$("excludeOverlap").checked || !overlap(a, rows[i]))).sort((i, j) => data.cosine[selected][j] - data.cosine[selected][i] || i - j).slice(0, 10);
    $("neighbors").replaceChildren();
    for (const index of nearest) {
      const item = document.createElement("li"), button = document.createElement("button");
      button.type = "button"; button.textContent = `${data.cosine[selected][index].toFixed(4)} · ${rows[index].label}${overlap(a, rows[index]) ? " · overlapping audio" : ""}`;
      button.onclick = () => { pair = index; inspect(); draw(); }; item.append(button); $("neighbors").append(item);
    }
  }
  function metricsText(name) {
    const m = data.metrics[name], number = value => value === null ? "undefined" : value.toFixed(3);
    return `${rows.length} samples · ${m.pairCount.toLocaleString()} pairs · Distance-rank correlation ${number(m.spearman)} · Scale-adjusted stress ${number(m.scaledStress)}`;
  }
  async function draw() {
    if (drawing) { redraw = true; return; }
    drawing = true;
    const renderedMode = mode;
    try {
    let traces, layout = {margin: {l: 45, r: 25, t: 20, b: 70}, paper_bgcolor: "white", plot_bgcolor: "white", font: {family: "system-ui", color: "#344256"}, hovermode: "closest", uirevision: renderedMode};
    if (renderedMode === "exact") {
      const order = data.heatmapOrder, positions = order.map((_, i) => i), ticks = [], labels = [];
      for (let i = 0; i < order.length;) { let end = i + 1; while (end < order.length && rows[order[end]].cluster === rows[order[i]].cluster) end++; ticks.push((i + end - 1) / 2); labels.push(plotText(rows[order[i]].cluster)); i = end; }
      traces = [{type: "heatmap", x: positions, y: positions, z: order.map(i => order.map(j => data.cosine[i][j])), zmin: -1, zmax: 1, colorscale: "RdBu", reversescale: true, colorbar: {title: {text: "Cosine"}, thickness: 13}, hovertemplate: "Row %{y}, column %{x}<br>Exact cosine %{z:.4f}<extra></extra>"}];
      const x = order.indexOf(pair), y = order.indexOf(selected);
      layout = {...layout, margin: {l: 110, r: 50, t: 20, b: 100}, xaxis: {tickvals: ticks, ticktext: labels, tickangle: -45, title: {text: "Comparison sample · existing cluster order"}}, yaxis: {tickvals: ticks, ticktext: labels, autorange: "reversed", title: {text: "Selected sample"}}, shapes: [{type: "rect", x0: x - .5, x1: x + .5, y0: y - .5, y1: y + .5, line: {color: "#111827", width: 3}}]};
      $("metrics").textContent = `${rows.length} samples · Exact normalized 256D cosine · Fixed color scale −1 to 1`;
      $("viewCaption").textContent = "Click a cell to compare its row and column samples, or use the two sample selectors. Cluster grouping changes display order only. The diagonal compares each sample with itself; it is excluded from projection metrics.";
    } else {
      const xy = data.coordinates[renderedMode];
      traces = clusters.map(cluster => {
        const ids = rows.filter(row => row.cluster === cluster).map(row => row.row);
        return {type: "scattergl", mode: "markers", name: plotText(cluster), x: ids.map(i => xy[i][0]), y: ids.map(i => xy[i][1]), customdata: ids, text: ids.map(i => plotText(rows[i].label)), hovertemplate: "%{text}<extra></extra>", marker: {color: colors.get(cluster), size: 8, opacity: .8, symbol: cluster === "Saved reference" ? "diamond" : "circle"}};
      });
      traces.push({type: "scattergl", mode: "markers", showlegend: false, x: [xy[selected][0], xy[pair][0]], y: [xy[selected][1], xy[pair][1]], customdata: [selected, pair], text: [plotText(rows[selected].label), plotText(rows[pair].label)], hovertemplate: "%{text}<extra></extra>", marker: {color: ["#111827", "#b45309"], size: 16, symbol: "circle-open", line: {width: 3}}});
      layout = {...layout, margin: {l: 45, r: 25, t: 20, b: 110}, legend: {orientation: "h", y: -.22}, xaxis: {title: {text: "Projection dimension 1"}, zeroline: false}, yaxis: {title: {text: "Projection dimension 2"}, zeroline: false, scaleanchor: "x", scaleratio: 1}};
      $("metrics").textContent = metricsText(renderedMode);
      $("viewCaption").textContent = renderedMode === "mds" ? "MDS approximates global Euclidean chord distances between normalized voice vectors. It uses no names or cluster labels. A nearby point can still be the wrong person; compare exact scores and audio." : "UMAP emphasizes neighborhoods. Distances between distant groups and the sizes of gaps are not calibrated voice similarities. Use the MDS view and exact scores to investigate them.";
    }
    await Plotly.react("plot", traces, layout, {responsive: true, displaylogo: false, modeBarButtonsToRemove: ["select2d", "lasso2d"]});
    $("plot").removeAllListeners("plotly_click");
    $("plot").on("plotly_click", event => { const point = event.points[0]; if (renderedMode === "exact") { selected = data.heatmapOrder[point.y]; pair = data.heatmapOrder[point.x]; } else { selected = point.customdata; } inspect(); draw(); });
    } catch (error) { $("error").textContent = `Couldn’t render this view. ${error.message}`; }
    finally { drawing = false; if (redraw) { redraw = false; draw(); } }
  }
  document.querySelectorAll("[data-mode]").forEach(button => { button.onclick = () => { mode = button.dataset.mode; document.querySelectorAll("[data-mode]").forEach(b => b.setAttribute("aria-pressed", b === button ? "true" : "false")); draw(); }; });
  $("sampleSelect").onchange = event => { selected = Number(event.target.value); inspect(); draw(); };
  $("pairSelect").onchange = event => { pair = Number(event.target.value); inspect(); draw(); };
  $("excludeOverlap").onchange = inspect;
  inspect(); await draw();
})().catch(error => { document.getElementById("error").textContent = `Couldn’t show the comparison. ${error.message}`; document.getElementById("metrics").textContent = "Comparison unavailable"; });
