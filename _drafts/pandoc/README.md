# Generetion gued of HTML, PDF and Slides from md files

### Convert to html
```bash
# Generate HTML
pandoc -s post.md -o ~/Documents/post2.html --template=github.html5 --self-contained
pandoc -s post2.md -o ~/Documents/post2.html --template=github.html5 --self-contained
```

### Convert to PDF
```bash
# Install XeLaTeX and font
brew install --cask mactex
export PATH=/Library/TeX/texbin:$PATH
brew install font-noto-sans-mono
```

```bash
# Generate PDF
pandoc -s post.md  -o ~/Documents/post2.pdf --pdf-engine=xelatex
pandoc -s post.md -o ~/Documents/post2.pdf --pdf-engine=xelatex -V monofont="DejaVu Sans Mono"
```

### Convert to Slides
```bash
# Generate Slides
pandoc -t revealjs -s slides.md -o ~/Documents/slides.html -V width=2560 -V height=1440 -V plugins=notes --css=custom.css
```
