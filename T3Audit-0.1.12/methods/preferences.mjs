// Replay selected local-only preferences. Import from the PID-guarded fixture driver.
import fs from "node:fs";
import path from "node:path";
export async function preferences(page,output,save,wait){
 const scope={
  general:["In-app notifications","Project grouping","Working section","Confirm thread unpinning","Confirm thread archiving","Confirm thread deletion","Confirm terminal closing"],
  appearance:["Render math","Wrap code, diffs, and file previews by default"],
  chat:["Rich text composer","Screen reader window title"],
  diffs:["Hide whitespace changes by default","Open pull requests and changes panels proactively","Open pull requests in T3 Code"],
  browser:["Auto-show floating preview","Show key presses in recordings","Show mouse presses in recordings"],
  worktrees:["Start new worktrees from remote by default"],
  labs:["Boring sidebar (group by project)","Suggest next prompt","Fast worktree checkout"]};
 const dest=path.join(output,"preferences-replay.json");const rows=fs.existsSync(dest)?JSON.parse(fs.readFileSync(dest)):[];page.setDefaultTimeout(2000);
 for(const [route,names] of Object.entries(scope)){
  await page.locator('[data-settings-section="/settings/'+route+'"]').click();await wait(180);
  for(const name of names){
   if(rows.some(r=>r.route===route&&r.name===name))continue;
   let before;
   try {
   const node=page.getByRole("switch",{name,exact:true}).first();
   if(!await node.count()||!await node.isEnabled()){rows.push({route,name,outcome:"conditional"});continue}
   const checked=()=>node.getAttribute("aria-checked");
   before=await checked();if(!["true","false"].includes(before))continue;
   await node.click();await wait(180);const changed=await checked();
   if(changed===before){rows.push({route,name,before,changed,outcome:"no change observed"});continue}
   await page.locator('[data-settings-section="/settings/about"]').click();await wait(140);
   await page.locator('[data-settings-section="/settings/'+route+'"]').click();await wait(180);
   const reopened=await checked();
   await node.click();await wait(160);
   const restored=await checked();if(restored!==before)throw Error("fixture preference restoration failed: "+name);
   rows.push({route,name,before,changed,reopened,restored,outcome:changed===reopened?"changed, persisted across view switch, restored":"different after view switch"});
   }catch(e){
      let now=null;try{const sw=page.getByRole("switch",{name,exact:true}).first();now=await sw.getAttribute("aria-checked",{timeout:260});if(before&&now&&now!==before)await sw.click({timeout:400});}catch{}
      rows.push({route,name,before,now,outcome:"control unavailable or transition not proved",error:e.name});
   }
   fs.writeFileSync(dest,JSON.stringify(rows,null,2));
  }
 }
 console.log("preference observations",rows.length);
}
