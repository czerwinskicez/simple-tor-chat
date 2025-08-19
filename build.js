const fs = require('fs');
const path = require('path');

const { minify: htmlMinify } = require('html-minifier-terser');
const CleanCSS = require('clean-css');
const terser = require('terser');

async function minifyFile(inputPath, outputPath) {
    // Read the private HTML file
    const htmlContent = fs.readFileSync(inputPath, 'utf8');

    // Extract JavaScript from HTML
    const jsRegex = /<script>([\s\S]*?)<\/script>/g;
    const cssRegex = /<style>([\s\S]*?)<\/style>/g;

    let jsMatch;
    let jsContent = '';
    while ((jsMatch = jsRegex.exec(htmlContent)) !== null) {
        jsContent += jsMatch[1] + '\n';
    }

    let cssMatch;
    let cssContent = '';
    while ((cssMatch = cssRegex.exec(htmlContent)) !== null) {
        cssContent += cssMatch[1] + '\n';
    }

    // Minify JavaScript with terser
    console.log(`Minifying JavaScript for ${path.basename(inputPath)}...`);
    const minifiedJsResult = await terser.minify(jsContent, {
        mangle: {
            toplevel: true,
        },
        compress: {
            drop_console: true,
        },
    });

    if (minifiedJsResult.error) {
        console.error(`Terser minification failed for ${path.basename(inputPath)}:`, minifiedJsResult.error);
        process.exit(1);
    }

    const minifiedJs = minifiedJsResult.code;

    // Minify CSS
    console.log(`Minifying CSS for ${path.basename(inputPath)}...`);
    const minifiedCss = new CleanCSS({
        level: 2,
        returnPromise: false
    }).minify(cssContent).styles;

    // Replace JS and CSS in HTML with minified versions
    let processedHtml = htmlContent;

    // Replace JavaScript
    processedHtml = processedHtml.replace(jsRegex, `<script>${minifiedJs}</script>`);

    // Replace CSS
    processedHtml = processedHtml.replace(cssRegex, `<style>${minifiedCss}</style>`);

    // Minify HTML
    console.log(`Minifying HTML for ${path.basename(inputPath)}...`);
    const minifiedHtml = htmlMinify(processedHtml, {
        collapseWhitespace: true,
        removeComments: true,
        removeRedundantAttributes: true,
        removeScriptTypeAttributes: true,
        removeStyleLinkTypeAttributes: true,
        minifyCSS: true,
        minifyJS: true,
        useShortDoctype: true,
        removeEmptyAttributes: true,
        removeOptionalTags: true,
        caseSensitive: true,
        preserveLineBreaks: false,
        preventAttributesEscaping: false
    });

    // Write the processed file to public directory
    fs.writeFileSync(outputPath, minifiedHtml, 'utf8');

    console.log(`Build for ${path.basename(inputPath)} completed successfully!`);
    console.log(`Original size: ${htmlContent.length} bytes`);
    console.log(`Minified size: ${minifiedHtml.length} bytes`);
    console.log(`Reduction: ${Math.round((1 - minifiedHtml.length / htmlContent.length) * 100)}%`);
    console.log(`Output: ${outputPath}`);
    console.log('---');
}

async function build() {
    // Ensure public directory exists
    const publicDir = path.join(__dirname, 'public');
    if (!fs.existsSync(publicDir)) {
        fs.mkdirSync(publicDir, { recursive: true });
    }

    const filesToBuild = ['index.html', 'info.html'];

    for (const file of filesToBuild) {
        const privatePath = path.join(__dirname, 'private', file);
        const publicPath = path.join(publicDir, file);
        await minifyFile(privatePath, publicPath);
    }

    console.log('All builds completed successfully!');
}

build();
