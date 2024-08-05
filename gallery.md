---
layout: default
title: Photo Gallery
permalink: /photos/
---

<h1>{{ page.title }}</h1>
<p>Welcome to the photo gallery! Select an album to view the photos:</p>

<div class="albums">
  {% if site.photos %}
    {% for gallery in site.photos %}
      <div class="album">
        <a href="{{ gallery.url }}">
          <img src="{{ gallery.thumbnail }}" alt="{{ gallery.title }} thumbnail">
          <h3>{{ gallery.title }}</h3>
        </a>
        <p>{{ gallery.description }}</p>
      </div>
    {% endfor %}
  {% else %}
    <p>No albums found.</p>
  {% endif %}
</div>
