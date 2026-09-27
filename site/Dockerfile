# Dockerfile: serves the site build (site/dist) with nginx as a non-root user
# on port 8080, with the security headers in nginx.conf. Build dist first
# with scripts/build-site.sh. GitHub Pages publishes the same dist/.
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist/ /usr/share/nginx/html/
# The base image's unprivileged nginx user (uid 101), stated explicitly.
USER 101
EXPOSE 8080
