#!/usr/bin/env python3
"""Save a web page with its style sheets, fonts and images, for scroll_bench.

    python3 -I tools/scroll_bench/save_page.py URL DIRECTORY

Writes DIRECTORY/index.html and DIRECTORY/res/*, with the page's references to style sheets,
images (src, srcset's first candidate, poster) and the url()s of the style sheets rewritten to
the saved copies. Scripts are dropped (the engine runs none yet). Real pages stay out of the
repository: save them in a scratch directory and point scroll_bench at them.
"""
import hashlib
import html.parser
import os
import re
import sys
import urllib.parse
import urllib.request

AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
LIMIT = 8 * 1024 * 1024


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": AGENT, "Accept-Encoding": "identity"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read(LIMIT), response.headers.get_content_charset() or "utf-8"


class Saver:
    def __init__(self, directory):
        self.directory = directory
        self.saved = {}
        os.makedirs(os.path.join(directory, "res"), exist_ok=True)

    def save(self, url, css=False):
        """The local path (relative to index.html) of url's saved copy, or url on failure."""
        if url in self.saved:
            return self.saved[url]
        if not url.startswith(("http://", "https://")):
            return url
        path = urllib.parse.urlparse(url).path
        extension = os.path.splitext(path)[1][:8] or (".css" if css else "")
        name = "res/" + hashlib.sha1(url.encode()).hexdigest()[:16] + extension
        self.saved[url] = name
        try:
            data, charset = fetch(url)
        except Exception as failure:  # a missing resource leaves its reference as it was
            print(f"save_page: {url}: {failure}", file=sys.stderr)
            self.saved[url] = url
            return url
        if css:
            text = data.decode(charset, errors="replace")
            data = self.rewrite_css(text, url, in_sheet=True).encode("utf-8")
        with open(os.path.join(self.directory, name), "wb") as file:
            file.write(data)
        return name

    def rewrite_css(self, text, base, in_sheet):
        def replace_url(match):
            reference = match.group(2).strip()
            if reference.startswith("data:") or not reference:
                return match.group(0)
            local = self.save(urllib.parse.urljoin(base, reference))
            # A style sheet's url()s resolve against the sheet itself (res/), the page's
            # against index.html.
            local = local[4:] if local.startswith("res/") and in_sheet else local
            return f'url("{local}")'

        def replace_import(match):
            local = self.save(urllib.parse.urljoin(base, match.group(2)), css=True)
            local = local[4:] if local.startswith("res/") and in_sheet else local
            return f'@import "{local}"'

        text = re.sub(r'@import\s+(["\'])([^"\']+)\1', replace_import, text)
        return re.sub(r'url\(\s*(["\']?)([^"\')]+)\1\s*\)', replace_url, text)


class Rewriter(html.parser.HTMLParser):
    def __init__(self, saver, base):
        super().__init__(convert_charrefs=False)
        self.saver = saver
        self.base = base
        self.out = []
        self.in_script = False
        self.in_style = False

    def handle_starttag(self, tag, attributes):
        self.out.append(self.tag_text(tag, attributes, close=False))

    def handle_startendtag(self, tag, attributes):
        self.out.append(self.tag_text(tag, attributes, close=True))

    def tag_text(self, tag, attributes, close):
        values = dict(attributes)
        if tag == "base" and values.get("href"):
            self.base = urllib.parse.urljoin(self.base, values["href"])
            return ""
        if tag == "script":
            self.in_script = True
            return ""
        if tag == "style":
            self.in_style = True
        kept = []
        for name, value in attributes:
            if value is None:
                kept.append(name)
                continue
            if name.startswith("on") or name in ("integrity", "crossorigin"):
                continue
            # Media is not played by the engine yet: a video or audio source is dropped (its
            # poster is kept).
            if name == "src" and tag in ("video", "audio", "source"):
                continue
            if tag == "link" and name == "href" and "stylesheet" in (values.get("rel") or ""):
                value = self.saver.save(urllib.parse.urljoin(self.base, value), css=True)
            elif tag == "link" and name == "href" and (values.get("rel") or "") in ("icon", "shortcut icon"):
                value = self.saver.save(urllib.parse.urljoin(self.base, value))
            elif name in ("src", "poster") and tag in ("img", "video", "input"):
                value = self.saver.save(urllib.parse.urljoin(self.base, value))
            elif name == "srcset":
                first = value.split(",")[0].strip().split(" ")[0]
                value = self.saver.save(urllib.parse.urljoin(self.base, first))
            elif name == "style":
                value = self.saver.rewrite_css(value, self.base, in_sheet=False)
            kept.append(f'{name}="{html.escape(value, quote=True)}"')
        text = "<" + " ".join([tag] + kept)
        return text + (" />" if close else ">")

    def handle_endtag(self, tag):
        if tag == "script":
            self.in_script = False
            return
        if tag == "style":
            self.in_style = False
        self.out.append(f"</{tag}>")

    def handle_data(self, data):
        if self.in_script:
            return
        if self.in_style:
            data = self.saver.rewrite_css(data, self.base, in_sheet=False)
        self.out.append(data)

    def handle_entityref(self, name):
        self.out.append(f"&{name};")

    def handle_charref(self, name):
        self.out.append(f"&#{name};")

    def handle_comment(self, data):
        pass

    def handle_decl(self, decl):
        self.out.append(f"<!{decl}>")


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    url, directory = sys.argv[1], sys.argv[2]
    data, charset = fetch(url)
    saver = Saver(directory)
    rewriter = Rewriter(saver, url)
    rewriter.feed(data.decode(charset, errors="replace"))
    rewriter.close()
    with open(os.path.join(directory, "index.html"), "w", encoding="utf-8") as file:
        file.write("".join(rewriter.out))
    print(f"save_page: {url} -> {directory} ({len(saver.saved)} resources)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
