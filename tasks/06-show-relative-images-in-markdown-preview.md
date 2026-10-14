---
status: todo
---
# Show relative images in Markdown previews

`portal-render-markdown` shows images with relative or local paths, such as
`![diagram](img/arch.png)`, inline in the preview, resolved from the displayed
document's folder like links are. Remote `https:` and `data:` images keep working.

Done when: a preview of a file with a relative image shows the image, the host
serves only image files through the new route, and the docs no longer list
relative inline images as unsupported.
