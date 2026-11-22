/* Agent Garrett's colour modes: light by default, one button to the green dark palette.
   Load it in the head, before the page paints. The reader's choice stays in this site's own storage. */
(()=>{
 'use strict';
 const root=document.documentElement,key='nl-veil-color-mode',valid=value=>value==='light'||value==='dark';
 let current='light';
 const stored=()=>{try{const value=localStorage.getItem(key);if(valid(value))return value;}catch{}return null;};
 // Before this switch, the site, the chat page and the desktop app kept a theme under 'veil.theme':
 // 'light', 'dark' (Tokyo Night) or 'matrix' (Agent Garrett's green). The chat page still syncs that
 // key with the desktop app. Returns 'light', 'dark', or null to ignore the value.
 function fromVeilTheme(value){
  if(value==='light')return 'light';
  if(value==='dark'||value==='matrix')return 'dark';
  return null;
 }
 const legacy=()=>{try{if(localStorage.getItem('veil.theme.chosen'))return fromVeilTheme(localStorage.getItem('veil.theme'));}catch{}return null;};
 const moon='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.5 13.2A8.6 8.6 0 0 1 10.8 3.5 8.7 8.7 0 1 0 20.5 13.2Z"/></svg>';
 const sun='<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/></svg>';
 function updateControls(){
  for(const button of document.querySelectorAll('[data-color-mode-toggle]')){
   const next=current==='light'?'dark':'light';
   button.setAttribute('aria-label','Switch to '+next+' mode');
   button.setAttribute('aria-pressed',String(current==='dark'));
   button.title='Switch to '+next+' mode';
   button.innerHTML=(next==='dark'?moon:sun)+'<span class="color-mode-label">'+(next==='dark'?'Dark':'Light')+'</span>';
  }
 }
 function apply(mode,persist=false){
  if(!valid(mode))return;current=mode;
  root.setAttribute('data-color-mode',mode);
  for(const meta of document.querySelectorAll('meta[name="theme-color"]'))meta.content=mode==='light'?'#ffffff':'#000000';
  if(persist){try{localStorage.setItem(key,mode);}catch{}}
  updateControls();
  document.dispatchEvent(new CustomEvent('garrett:color-mode',{detail:{mode}}));
 }
 function mount(){
  if(!document.querySelector('[data-color-mode-toggle]')){
   const button=document.createElement('button');button.type='button';button.className='color-mode-toggle color-mode-fallback';button.setAttribute('data-color-mode-toggle','');
   document.body.append(button);
  }
  updateControls();
 }
 window.garrettColorMode={get:()=>current,set:mode=>apply(mode,true),fromVeilTheme};
 apply(stored()||legacy()||'light');
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount,{once:true});else mount();
 document.addEventListener('click',event=>{if(event.target.closest?.('[data-color-mode-toggle]'))apply(current==='light'?'dark':'light',true);});
 addEventListener('storage',event=>{if(event.key===key&&valid(event.newValue))apply(event.newValue);});
 addEventListener('pageshow',()=>{const value=stored();if(value&&value!==current)apply(value);});
})();
