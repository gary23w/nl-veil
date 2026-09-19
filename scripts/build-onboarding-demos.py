"""Render captioned tutorials from explicitly reviewed, account-free screenshots.

Usage: python scripts/build-onboarding-demos.py --frames PATH --ffmpeg PATH
Only three allowlisted screenshots are accepted. No runtime state is copied.
"""
import argparse
import json
import math
import subprocess
import textwrap
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "demos"
W, H, FPS = 1600, 900, 15
BG, FG, MUTED = "#10141f", "#f4f5ff", "#bdc6dc"
PURPLE, CYAN = "#bd9bff", "#77dfdf"
FONT = Path("C:/Windows/Fonts")

def font(size, bold=False):
    return ImageFont.truetype(str(FONT / ("segoeuib.ttf" if bold else "segoeui.ttf")), size)

def lines(draw, text, xy, size, color=FG, width=38, bold=False, gap=12):
    x, y = xy
    for line in textwrap.wrap(text, width):
        draw.text((x, y), line, font=font(size, bold), fill=color)
        y += size + gap
    return y

def mark(draw,x,y,r,color):
    draw.polygon([(x,y-r),(x+r*.26,y-r*.26),(x+r,y),(x+r*.26,y+r*.26),(x,y+r),(x-r*.26,y+r*.26),(x-r,y),(x-r*.26,y-r*.26)],fill=color)

INSTALL = [
    dict(title="From download\nto desktop.", text="Get the Veil running on Windows.", tag="01 / DOWNLOAD & RUN", kind="title", secs=6,
         caption="The Veil is an open-source desktop app for building software with AI. This walkthrough uses version 1.1.3 on Windows."),
    dict(title="Get the desktop ZIP.", text="Open the latest release. Expand Assets and choose your platform's full desktop bundle.", kind="downloads", secs=10,
         caption="Visit github.com/gary23w/nl-veil/releases/latest. Under Assets, choose the full desktop ZIP for your operating system. This recording uses version 1.1.3; newer versions may differ."),
    dict(title="Extract the whole folder.", text="On Windows: right-click the ZIP, choose Extract All, then open the extracted folder.", kind="files", secs=9,
         caption="Extract the full ZIP into a writable folder. Keep veil.exe, the bin folder and veil-install.txt together. Source code archives and veil-server files are different downloads."),
    dict(title="Open veil.exe.", text="Double-click the app in the extracted folder. The desktop workspace opens.", kind="screenshot", image="desktop", secs=9,
         caption="Double-click veil.exe. These release builds are unsigned. Follow your operating system's approval flow only for a release you trust; managed devices may require an administrator."),
    dict(title="Choose your AI.", text="Use Cloudflare AI to start without downloading local model weights. Or choose a local model.", kind="screenshot", image="cloudflare-login", crop=(0,420,780,810), secs=9,
         caption="Open Settings to choose your provider. Cloudflare AI needs an internet connection and an account. Local inference uses separately downloaded model weights. Coding tools need Python; some checks also need Node."),
    dict(title="Your first conversation.", text="Next: connect Cloudflare AI and send a simple first prompt.", kind="screenshot", image="chat", secs=7,
         caption="Open Chat and send a small, specific request after selecting a working model. Watch the second tutorial for Cloudflare sign-in and a real example reply."),
]
CF = [
    dict(title="Connect\nCloudflare AI.", text="Your account. Your model choice. A simple first conversation.", tag="02 / CLOUDFLARE AI", kind="title", secs=6,
         caption="Use Cloudflare Workers AI inside the Veil. This tutorial combines real clean-profile app screens with instruction cards. Private authentication is not recorded."),
    dict(title="Open Settings.", text="Scroll to Cloudflare login, then choose Log in with Cloudflare.", kind="screenshot", image="cloudflare-login", crop=(0,420,780,810), secs=8,
         caption="In the Veil, open Settings and scroll to Cloudflare login. Choose Log in with Cloudflare. The app opens Cloudflare in your browser; there is no token to paste."),
    dict(title="Sign in privately.", text="In your browser, sign in to Cloudflare and choose the account you want the Veil to use.", kind="privacy", secs=8,
         caption="Sign in to Cloudflare in your browser and select your account. Passwords, email addresses, account IDs and authentication screens are deliberately omitted from this tutorial."),
    dict(title="Review the permissions.", text="Review Cloudflare's consent screen. Optional deployment, storage and domain permissions can be declined.", kind="permissions", secs=10,
         caption="Review the required identity, account and Workers AI permissions. Decline optional permissions you do not need. Optional R2 access enables chat backups and may require R2 activation. Complete the consent step yourself, then return to the Veil."),
    dict(title="Choose a model.", text="After sign-in, check Settings: use Cloudflare Workers AI and choose from your account's model list.", kind="models", secs=9,
         caption="After successful login, the Veil switches chat to Workers AI and fetches your account's model list. Verify the provider and model in Settings. Model availability and prices vary; some models require paid billing."),
    dict(title="Ask something simple.", text="Open Chat. Ask for a first project idea, then check the reply.", kind="reply", secs=12,
         caption="A real demo request through the Veil, using Cloudflare's Llama 3.3 70B model, returned: Why not start by building a simple to-do list app to get familiar with coding and see your progress come to life. The response is typeset here to exclude account information."),
    dict(title="Know what leaves\nyour machine.", text="Cloudflare AI processes prompts in the cloud. Check usage and pricing in your own account.", kind="finish", secs=9,
         caption="Cloudflare Workers AI processes prompts remotely. Its current free allowance is 10,000 neurons per day, with paid requirements for some models. Check current pricing and usage. You can disconnect in Settings, or switch to a local provider."),
]

def base_frame(scene, frames, i, count, elapsed=0):
    im = Image.new("RGB", (W,H), BG)
    d = ImageDraw.Draw(im)
    mark(d,80,59,14,PURPLE)
    d.text((108,38), "the veil", font=font(30, True), fill=FG)
    d.text((1150,46), "GET STARTED  /  v1.1.3", font=font(19), fill=MUTED)
    d.line((64,98,1536,98), fill="#30384b", width=2)
    d.text((66,137), scene.get("tag", f"STEP {i:02d} / {count-1:02d}"), font=font(18,True), fill=CYAN)
    y=197
    for row in scene["title"].split("\n"):
        y=lines(d,row,(66,y),43,width=21,bold=True,gap=12)
    lines(d,scene["text"],(66,y+25),25,color=MUTED,width=29,gap=12)
    x0,y0,x1,y1=555,140,1536,786
    d.rounded_rectangle((x0,y0,x1,y1),radius=24,fill="#1a2232",outline="#36435b",width=2)
    k=scene["kind"]
    if k=="screenshot":
        shot=Image.open(frames/(scene["image"]+".png")).convert("RGB")
        shot.thumbnail((x1-x0-28,y1-y0-70),Image.Resampling.LANCZOS)
        im.paste(shot,(x0+(x1-x0-shot.width)//2,y0+48+(y1-y0-62-shot.height)//2))
        d.text((x0+24,y0+16),"ACTUAL APP SCREEN · CLEAN DEMO PROFILE",font=font(16,True),fill=CYAN)
    elif k=="downloads":
        d.text((595,175),"CHOOSE YOUR DESKTOP BUNDLE",font=font(23,True),fill=CYAN)
        for j,(label,name) in enumerate([("Windows","windows-x86_64"),("Mac · Apple Silicon","macos-arm64"),("Mac · Intel","macos-x86_64"),("Linux","linux-x86_64")]):
            y=240+j*107
            d.rounded_rectangle((586,y,1504,y+87),radius=14,fill="#29354c",outline=PURPLE if j==0 else "#36435b",width=2)
            d.text((610,y+12),label,font=font(23,True),fill=FG)
            d.text((610,y+46),f"veil-v1.1.3-{name}.zip",font=font(22),fill=MUTED)
        lines(d,"Instruction card · filenames verified against the published release",(595,699),18,MUTED,width=75)
    elif k=="files":
        d.text((595,177),"KEEP THE BUNDLE TOGETHER",font=font(24,True),fill=CYAN)
        for j,(a,b) in enumerate([("veil.exe","Open this on Windows"),("bin/","Keep the memory engine beside the app"),("veil-install.txt","Keep this installation marker")]):
            y=270+j*124
            d.text((620,y),a,font=font(33,True),fill=FG)
            d.text((620,y+47),b,font=font(22),fill=MUTED)
        lines(d,"macOS / Linux: run ./veil from the extracted folder.",(620,675),24,MUTED,width=53)
    elif k=="privacy":
        d.text((610,230),"PRIVATE STEP",font=font(40,True),fill=PURPLE)
        lines(d,"Complete sign-in in your own browser.",(610,319),35,width=36,bold=True)
        lines(d,"No passwords, emails, account IDs, codes or consent URLs appear in this video.",(610,474),28,MUTED,width=45)
        d.text((610,693),"Instruction card · authentication omitted",font=font(21),fill=CYAN)
    elif k=="permissions":
        for y,title,body in [(205,"Required for chat","Identity, account access and Workers AI"),(345,"Optional capabilities","Review deployment, storage and domain scopes"),(485,"Your choice","Decline optional access you do not need")]:
            d.text((605,y),title,font=font(31,True),fill=FG)
            lines(d,body,(605,y+49),25,MUTED,width=48)
        lines(d,"Instruction card · review the actual Cloudflare consent screen",(605,682),20,CYAN,width=65)
    elif k=="models":
        for y,a,b in [(215,"1  Return to the Veil","Check that Cloudflare is connected."),(360,"2  Check the provider","Settings → Cloudflare Workers AI"),(505,"3  Pick an available model","Use your account's live model list.")]:
            d.text((605,y),a,font=font(31,True),fill=FG)
            lines(d,b,(605,y+50),26,MUTED,width=46)
        d.text((605,699),"Instruction card · after successful sign-in",font=font(21),fill=CYAN)
    elif k=="reply":
        d.text((596,176),"ACTUAL WORKERS AI RESULT",font=font(24,True),fill=CYAN)
        lines(d,"Prompt: suggest a first project for someone learning to build software.",(598,247),28,MUTED,width=47)
        lines(d,"“Why not start by building a simple to-do list app to get familiar with coding and see your progress come to life.”",(598,388),34,width=43,bold=True)
        lines(d,"Llama 3.3 70B · via the Veil · 19 September 2026",(598,671),21,CYAN,width=62)
        d.text((598,720),"Typeset transcript · private account details excluded",font=font(19),fill=MUTED)
    elif k=="finish":
        lines(d,"10,000 neurons / day",(610,232),40,width=30,bold=True)
        lines(d,"Current free allowance. Some models require paid billing. Check Cloudflare's current pricing.",(610,330),28,MUTED,width=43)
        lines(d,"Cloud inference sends prompts to Cloudflare.",(610,520),33,width=37,bold=True)
        d.text((610,701),"Pricing checked 19 September 2026",font=font(22),fill=CYAN)
    else:
        mark(d,700,301,52,PURPLE)
        lines(d,"An AI coding team that remembers your project.",(642,414),43,width=29,bold=True)
        d.text((642,663),"Windows · macOS · Linux",font=font(27),fill=CYAN)
    d.text((66,820),"gary23w.github.io/nl-veil/demos/",font=font(22),fill=MUTED)
    d.text((1060,823),"Edited tutorial · private login omitted",font=font(18),fill=MUTED)
    d.rectangle((64,875,1536,880),fill="#30384b")
    d.rectangle((64,875,64+int(1472*(i+elapsed)/count),880),fill=PURPLE)
    return im

def stamp(seconds):
    seconds=int(seconds)
    return f"00:{seconds//60:02d}:{seconds%60:02d}.000"

def build(name,scenes,frames,encoder):
    OUT.mkdir(parents=True,exist_ok=True)
    for filename in ["desktop", "cloudflare-login", "chat"]:
        # Re-encode pixels only, stripping source metadata.
        source=Image.open(frames/(filename+".png")).convert("RGB")
        # Hard crop the Settings image BELOW every data-directory/account field.
        # Never copy a full Settings screenshot to public output, even transiently.
        if filename=="cloudflare-login":
            safe=source.crop((0,420,780,810))
        elif filename=="chat":
            safe=source.crop((253,115,877,711))
        else:
            safe=source.crop((0,34,733,810))
        sd=ImageDraw.Draw(safe)
        safe.save(OUT/(filename+".png"))
    # Render exclusively from the sanitized, metadata-free public copies.
    frames=OUT
    base_frame(scenes[0],frames,0,len(scenes)).save(OUT/(name+"-poster.jpg"),quality=90)
    cmd=[encoder,"-y","-loglevel","error","-f","rawvideo","-vcodec","rawvideo","-pix_fmt","rgb24","-s",f"{W}x{H}","-r",str(FPS),"-i","-","-an","-c:v","libx264","-preset","fast","-crf","23","-pix_fmt","yuv420p","-movflags","+faststart","-map_metadata","-1",str(OUT/(name+".mp4"))]
    p=subprocess.Popen(cmd,stdin=subprocess.PIPE)
    subtitles=["WEBVTT\n"]
    seconds=0
    for i,s in enumerate(scenes):
        subtitles.append(f"{stamp(seconds)} --> {stamp(seconds+s['secs'])}\n{s['caption']}\n")
        seconds+=s["secs"]
        # Half-second progress increments retain a clear, calm reading pace.
        for f in range(s["secs"]*FPS):
            frame=base_frame(s,frames,i,len(scenes),f/(s["secs"]*FPS))
            p.stdin.write(frame.tobytes())
        base_frame(s,frames,i,len(scenes)).save(OUT/(name+f"-scene-{i}.jpg"),quality=86)
    p.stdin.close()
    if p.wait()!=0: raise RuntimeError("Video encoding failed")
    (OUT/(name+".vtt")).write_text("\n".join(subtitles),encoding="utf-8")
    (OUT/(name+"-transcript.txt")).write_text("\n\n".join(s["caption"] for s in scenes),encoding="utf-8")
    print(f"{name}: {seconds}s, {(OUT/(name+'.mp4')).stat().st_size:,} bytes",flush=True)

if __name__=="__main__":
    ap=argparse.ArgumentParser()
    ap.add_argument("--frames",type=Path,required=True)
    ap.add_argument("--ffmpeg",required=True)
    a=ap.parse_args()
    build("download-and-run",INSTALL,a.frames,a.ffmpeg)
    build("cloudflare-ai",CF,a.frames,a.ffmpeg)
