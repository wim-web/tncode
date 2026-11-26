import fs from "node:fs";
import path from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
const [root, ...ops] = process.argv.slice(2);
if (fs.readFileSync(path.join(root,"audit-owned"),"utf8").trim() !== "t3-0.1.12") throw Error("unknown fixture");
const pid=Number(fs.readFileSync(path.join(root,"fixture.pid"),"utf8"));
const bound=execFileSync("/usr/sbin/lsof",["-nP","-a","-p",String(pid),"-iTCP:47861","-sTCP:LISTEN"]).toString();
if (!bound.includes("127.0.0.1:47861")) throw Error("fixture is not listening");
const { chromium }=await import(pathToFileURL(path.join(root,"playwright-core/index.mjs")));
const browser=await chromium.connectOverCDP("http://127.0.0.1:47861", {timeout:8000});
const pages=browser.contexts().flatMap(c=>c.pages());
const page=pages.find(p=>/^t3[a-z-]*:\/\/app\b/.test(p.url()));
if(!page) throw Error("fixture renderer unavailable: "+pages.map(p=>p.url().split(/[?#]/)[0]).join(" "));
const cdp=await page.context().newCDPSession(page);
const output=process.env.T3_AUDIT_OUTPUT||path.join(root,"receipts");
fs.mkdirSync(output,{recursive:true});
const wait=ms=>new Promise(r=>setTimeout(r,ms));
const clean=s=>s.replace(/[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}/g,"[address]").replace(/([?&#](?:token|key|code)=)[^&#\s]+/gi,"$1[redacted]");
const controlSelector='button,[role="button"],a,[role="menuitem"],[role="option"],[role="tab"],[role="switch"],[role="combobox"],input,textarea,[contenteditable="true"],[data-panel],dialog,[role="dialog"],header,main,nav,aside,h1,h2,h3,[data-slot]';
async function surface(){
 return await page.evaluate((selector)=>{
  const round=n=>Math.round(n*10)/10,rect=r=>[r.x,r.y,r.width,r.height].map(round);
  const name=e=>[e.getAttribute("aria-label"),e.getAttribute("title"),e.getAttribute("placeholder"),e.getAttribute("aria-placeholder"),e.getAttribute("data-placeholder"),e.innerText?.trim().slice(0,90)].filter(Boolean)[0]||"";
  return {urlPath:location.pathname,window:[window.outerWidth,window.outerHeight],viewport:[innerWidth,innerHeight],dpr:devicePixelRatio,lang:document.documentElement.lang,
   dark:matchMedia("(prefers-color-scheme: dark)").matches,rootClass:document.documentElement.className,background:getComputedStyle(document.body).backgroundColor,
   focus:{tag:document.activeElement?.tagName,role:document.activeElement?.getAttribute("role"),name:name(document.activeElement)},
   elements:[...document.querySelectorAll(selector)].filter(e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width&&r.height&&s.visibility!=="hidden"&&s.display!=="none"&&r.bottom>0&&r.top<innerHeight}).map(e=>{
    const s=getComputedStyle(e),r=e.getBoundingClientRect();
    return {tag:e.tagName.toLowerCase(),role:e.getAttribute("role"),name:name(e),slot:e.getAttribute("data-slot"),panel:e.getAttribute("data-panel"),testId:e.getAttribute("data-testid"),placeholder:e.getAttribute("placeholder"),aria:e.getAttribute("aria-label"),title:e.getAttribute("title"),disabled:e.matches(":disabled")||e.getAttribute("aria-disabled")==="true",rect:rect(r),padding:[s.paddingTop,s.paddingRight,s.paddingBottom,s.paddingLeft],gap:s.gap,radius:s.borderRadius,font:[s.fontFamily,s.fontSize,s.fontWeight,s.lineHeight],foreground:s.color,background:s.backgroundColor,icon:e.querySelector("svg")?.getAttribute("class")||null};
   })};
 },controlSelector);
}
async function save(id) {
 if(!/^[a-zA-Z0-9_-]+$/.test(id)) throw Error("invalid state id");
 const data=await surface();
 fs.writeFileSync(path.join(output,id+".json"),clean(JSON.stringify({at:new Date().toISOString(),...data},null,2))+"\n");
 const image=await cdp.send("Page.captureScreenshot",{format:"png",fromSurface:true,captureBeyondViewport:false});
 fs.writeFileSync(path.join(output,id+".png"),Buffer.from(image.data,"base64"));
 console.log(id,data.viewport,data.dpr,data.elements.length);
}
async function describe(){
 const s=await surface();
 console.log(JSON.stringify({window:s.window,viewport:s.viewport,dpr:s.dpr,theme:s.rootClass,path:s.urlPath,focus:s.focus}));
 console.log(clean((await page.locator("body").innerText()).slice(0,5500)));
 console.log(clean(JSON.stringify(s.elements.filter(e=>e.aria||e.title||e.placeholder||["input","textarea"].includes(e.tag)).map(e=>[e.tag,e.role,e.aria,e.title,e.placeholder,e.rect]).slice(0,125))));
}
async function film(id, action, duration=1800) {
 if(!/^[a-zA-Z0-9_-]+$/.test(id)) throw Error("invalid clip id");
 const dir=fs.mkdtempSync(path.join(root,"frames-")), frames=[];
 const start=performance.now();
 const click=(async()=>{await wait(260);await action()})();
 while(performance.now()-start<duration){
  const t=performance.now()-start;
  const shot=await cdp.send("Page.captureScreenshot",{format:"png",fromSurface:true});
  const name="f"+frames.length+".png";
  fs.writeFileSync(path.join(dir,name),Buffer.from(shot.data,"base64"));
  frames.push({name,t});await wait(45);
 }
 await click;
 let manifest="";
 frames.forEach((f,i)=>{manifest+="file "+f.name+"\nduration "+(((frames[i+1]?.t??(f.t+70))-f.t)/1000).toFixed(4)+"\n";});manifest+="file "+frames.at(-1).name+"\n";
 fs.writeFileSync(path.join(dir,"manifest"),manifest);
 execFileSync("ffmpeg",["-nostdin","-loglevel","error","-y","-f","concat","-safe","1","-i",path.join(dir,"manifest"),"-fps_mode","vfr","-c:v","libx264","-pix_fmt","yuv420p","-movflags","+faststart",path.join(output,id+".mp4")]);
 fs.writeFileSync(path.join(output,id+".timing.json"),JSON.stringify({capture:"Page.captureScreenshot",timesMs:frames.map(f=>Math.round(f.t)),actionAfterMs:260,elapsedMs:Math.round(performance.now()-start)},null,2));
}
async function surveyPanels(){
 let add=page.getByLabel("Add panel surface",{exact:true});
 if(!await add.count()) await page.getByLabel("Toggle right panel",{exact:true}).click();
 await wait(200);
 const outcomes=[];
 for(const [label,id] of [["Files","files"],["Diff","diff"],["Linked items","linked"],["Pull request","pr"],["Device","device"],["Side chat","sidechat"],["Browser","browser"],["Terminal","terminal"]]){
  try{
   if(await add.count()) await add.click({timeout:1700});
   let opt=page.getByRole("menuitem",{name:new RegExp("^"+label)});
   if(!await opt.count()) opt=page.getByRole("button",{name:new RegExp("^"+label+"(?:\\s|$)")}).last();
   if(!await opt.isEnabled({timeout:1200})){outcomes.push([label,"disabled"]);await page.keyboard.press("Escape");continue}
   await opt.click({timeout:1700});await wait(700);
   await save("T3-P-"+id);outcomes.push([label,"opened"]);
  }catch(e){outcomes.push([label,"unavailable at this step"]);await page.keyboard.press("Escape")}
 }
 fs.writeFileSync(path.join(output,"panel-outcomes.json"),JSON.stringify(outcomes));console.log(outcomes);
}
async function surveySettings(){
 const nav=page.locator("[data-settings-section]");
 const sections=await nav.evaluateAll(rows=>rows.map(e=>({route:e.dataset.settingsSection,name:e.innerText})));
 const result=[];
 for(const {route,name} of sections){
  await page.locator("[data-settings-section="+JSON.stringify(route)+"]").click({timeout:2600});
  await wait(260);
  const scroll=page.locator("[data-settings-page-scroll]").last();
  const getInfo=()=>scroll.evaluate(e=>{
   const root=e.getBoundingClientRect();
   return {offset:Math.round(e.scrollTop),height:e.clientHeight,total:e.scrollHeight,
    anchors:[...e.querySelectorAll("[id]")].filter(q=>q.id && !/^(:|_|base-ui|radix)/.test(q.id)).map(q=>({id:q.id,text:(q.querySelector("label,h2,h3")?.textContent||q.getAttribute("aria-label")||"").slice(0,85),inView:q.getBoundingClientRect().top<root.bottom&&q.getBoundingClientRect().bottom>root.top})),
    controls:[...e.querySelectorAll("button,input,select,textarea,[role=switch],[role=combobox]")].filter(q=>q.getBoundingClientRect().height>0).map(q=>({name:(q.getAttribute("aria-label")||q.getAttribute("placeholder")||q.innerText||"").trim().slice(0,70),role:q.getAttribute("role")||q.tagName,disabled:q.matches(":disabled")||q.getAttribute("aria-disabled")==="true"}))};
  });
  const captures=[];const slug=route.split("/").filter(Boolean).pop();
  if(!await scroll.count()){await save("T3-S-"+slug);result.push({name,route,captures:[{id:"T3-S-"+slug}]});continue}
  await scroll.evaluate(e=>e.scrollTo({top:0,behavior:"instant"}));await wait(80);
  for(let i=0;i<45;i++){
   const info=await getInfo(),id="T3-S-"+slug+(i?"-"+(i+1):"");
   await save(id);captures.push({id,...info});
   if(info.offset+info.height>=info.total-2 || info.height<10)break;
   const next=await scroll.evaluate(e=>{e.scrollBy({top:Math.round(e.clientHeight*.87),behavior:"instant"});return Math.round(e.scrollTop)});
   if(next<=info.offset)break;
   await wait(90);
  }
  result.push({name,route,captures});fs.writeFileSync(path.join(output,"settings-outcomes.json"),clean(JSON.stringify(result,null,2)));
 }
 console.log("settings sections",result.length);
}
const locator=(spec)=>{
 if(spec.startsWith("text=")) return page.getByText(spec.slice(5),{exact:true}).first();
 if(spec.startsWith("label=")) return page.getByLabel(spec.slice(6),{exact:true}).first();
 if(spec.startsWith("title=")) return page.getByTitle(spec.slice(6),{exact:true}).first();
 return page.locator(spec).first();
};
for (let i=0;i<ops.length;i++){
 const op=ops[i];
 if(op==="widths"){
   for(const w of [900,1080,1440]){
    let report;
    try {report=execFileSync(path.join(root,"size-window"),[String(pid),String(w),"720"],{encoding:"utf8"}).trim();} catch {report="AX did not confirm the target size";}
    await wait(450);
    let actual=await page.evaluate(()=>[outerWidth,innerWidth]);
    const mode=actual[1]===w?"native":"renderer-viewport";
    if(mode==="renderer-viewport"){await cdp.send("Emulation.setDeviceMetricsOverride",{width:w,height:720,deviceScaleFactor:1,mobile:false});await wait(150);}
    actual=await page.evaluate(()=>[outerWidth,innerWidth]);if(actual[1]!==w)throw Error("viewport mismatch");
    fs.writeFileSync(path.join(output,"width-"+w+".json"),JSON.stringify({requested:w,mode,outer:actual[0],viewport:actual[1],ax:report}));
    
    const details=page.getByLabel("Toggle thread details panel",{exact:true}).first(),pane=page.getByLabel("Toggle right panel",{exact:true}).first();
    const shown=()=>page.locator('[aria-label^="Run context:"]:visible').count();
    if(await shown()){await details.click();await wait(300);}
    if(await shown())throw Error("details did not close");
    await save("T3-W"+w+"-draft");
    await details.click();await wait(300);if(!await shown())throw Error("details did not open");
    await save("T3-W"+w+"-details");await details.click();await wait(250);
    await pane.click();await wait(350);
    await save("T3-W"+w+"-right");await pane.click();await wait(350);
   }
   await cdp.send("Emulation.clearDeviceMetricsOverride").catch(()=>{});try{execFileSync(path.join(root,"size-window"),[String(pid),"1080","720"]);}catch{}await wait(350);
 }
 else if(op==="preferences"){const {preferences}=await import("./preferences.mjs");await preferences(page,output,save,wait);}
 else if(op==="settings") await surveySettings();
 else if(op==="panels") await surveyPanels();
 else if(op==="filmLong"){const id=ops[++i],l=locator(ops[++i]);await film(id,()=>l.click({timeout:3000}),5200);}
 else if(op==="film"){const id=ops[++i],l=locator(ops[++i]);await film(id,()=>l.click({timeout:3000}));}
 else if(op==="dialogText"){for(const d of await page.locator("[role=dialog],[role=alertdialog]").all())if(await d.isVisible())console.log(clean((await d.innerText()).slice(-1250)));}
 else if(op==="brief"){console.log(clean((await page.locator("body").innerText()).slice(-2400)));console.log(JSON.stringify((await surface()).elements.filter(e=>e.aria||e.title).map(e=>e.aria||e.title).slice(-36)));}
 else if(op==="controls"){console.log(JSON.stringify((await surface()).elements.filter(e=>e.tag==="button"||e.role==="menuitem"||e.tag==="a").map(e=>[e.role,e.name,e.rect.slice(0,2)]).slice(-70)));}
 else if(op==="terminalCheck"){const name=ops[++i];if(!/^[a-z]+$/.test(name))throw Error("receipt name");const receipt=path.join(root,"terminal-"+name+".txt");const t=page.getByLabel("Terminal input",{exact:true}).last();await t.focus();await page.keyboard.press("Control+u");await page.keyboard.type("pwd > "+receipt+"; tty >> "+receipt+"; pwd; tty",{delay:2});await page.keyboard.press("Enter");await wait(450);}
 else if(op==="quit"){await cdp.send("Browser.close").catch(()=>{});process.exit(0);}
 else if(op==="resize"){const w=Number(ops[++i]),h=Number(ops[++i]);execFileSync(path.join(root,"size-window"),[String(pid),String(w),String(h)]);await wait(400);}
 else if(op==="describe") await describe();
 else if(op==="save") await save(ops[++i]);
 else if(op==="wait") await wait(Number(ops[++i]));
 else if(op==="click"||op==="right"||op==="hover"){const l=locator(ops[++i]);if(op==="hover") await l.hover({timeout:3000});else await l.click({button:op==="right"?"right":"left",timeout:3000});}
 else if(op==="waitText"){await page.getByText(ops[++i],{exact:false}).last().waitFor({state:"visible",timeout:10000});}
 else if(op==="key") await page.keyboard.press(ops[++i]);
 else if(op==="type") await page.keyboard.insertText(ops[++i]);
 else if(op==="fill"){const l=locator(ops[++i]);await l.fill(ops[++i],{timeout:3000});}
 else if(op==="dark") await cdp.send("Emulation.setEmulatedMedia",{features:[{name:"prefers-color-scheme",value:"dark"}]});
 else throw Error("unknown operation: "+op);
}
process.exit(0);
