# Dockerfile: serves the site build (site/dist) with nginx as a non-root user
# on port 8080, with the security headers in nginx.conf. Build dist first
# with scripts/build-site.sh. GitHub Pages publishes the same dist/.
# Pinned by digest so a re-pushed tag cannot change the image; the tag is 1.27-alpine.
FROM nginxinc/nginx-unprivileged:1.27-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist/ /usr/share/nginx/html/
# The base image's unprivileged nginx user (uid 101), stated explicitly.
USER 101
EXPOSE 8080
