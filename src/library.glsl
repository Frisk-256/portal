#version 460
#extension GL_ARB_gpu_shader_fp64 : require
// Version can't be changed to upper versions because of WebGL.

// precision highp float;

uniform int _black_border_disable;

// ---------------------------------------------------------------------------
// Scalar math ---------------------------------------------------------------
// ---------------------------------------------------------------------------


double dsin(double x) { return double(sin(float(x))); } // !RETAIN_FLOAT!
double dcos(double x) { return double(cos(float(x))); } // !RETAIN_FLOAT!
double dtan(double x) { return double(tan(float(x))); } // !RETAIN_FLOAT!
double dacos(double x) { return double(acos(float(x))); } // !RETAIN_FLOAT!
double datan(double x, double y) { return double(atan(float(x), float(y))); } // !RETAIN_FLOAT!
double dexp2(double x) { return double(exp2(float(x))); } // !RETAIN_FLOAT!
double dlog2(double x) { return double(log2(float(x))); }  // !RETAIN_FLOAT!

#define PI acos(-1.)
#define PI2 (acos(-1.) / 2.0)
    
// Checks if `x` is in range [a, b].
bool between(float a, float x, float b) {
    return a <= x && x <= b;
}

// Returns square of input.
float sqr(float a) {
    return a*a;
}

vec4 texture(sampler2D tex, vec2 pos) {
    return texture2D(tex, vec2(pos.x, pos.y)); // !RETAIN_FLOAT!
}

// ---------------------------------------------------------------------------
// Vector and ray math -------------------------------------------------------
// ---------------------------------------------------------------------------

struct Ray
{
    vec4 o; // Origin.
    vec4 d; // Direction.
    float tmul; // T multiplier
};

Ray offset_ray(Ray r, float t) {
    r.o += r.d * t;
    return r;
}

const Ray ray_none = Ray(vec4(0.), vec4(0.), 0.);

// Returns normal that anti-directed to dir ray, and has length 1.
vec3 normalize_normal(vec3 normal, vec3 dir) {
    normal = normalize(normal);
    if (dot(normal, dir) > 0.) {
        normal *= -1.;
    }
    return normal;
}

// Is two vectors has same direction.
bool is_collinear(vec3 a, vec3 b) {
    return abs(dot(a, b) / (length(a) * length(b)) - 1.) < 0.01;
}

// Return reflected dir vector, based on normal and current dir.
vec3 my_reflect(vec3 dir, vec3 normal) {
     return dir - normal * dot(dir, normal) / dot(normal, normal) * 2.;
}

// Return refracted dir vector, based on normal and current dir.
vec3 my_refract(vec3 dir, vec3 normal, float refractive_index) {
    float ri = refractive_index;
    bool from_outside = dot(normal, dir) > 0.;
    if (!from_outside) {
        ri = 1. / ri;
    } else {
        normal = -normal;
    }

    dir = normalize(dir);
    float c = -dot(normal, dir);
    float d = 1.0 - ri * ri * (1.0 - c*c);
    if (d > 0.) {
        return dir * ri + normal * (ri * c - sqrt(d));
    } else {
        return my_reflect(dir, normal);
    }
}

// Return ray, trat is transformed used matrix. NOTE: Do not forget to normalize new r.d!!! If your `t` depends on it, memorize it somewhere.
Ray transform(mat4 matrix, Ray r) {
    return Ray(
        matrix * r.o,
        matrix * r.d,
        r.tmul
    );
}

vec3 get_normal(mat4 matrix) {
    return (matrix * vec4(0., 0., 1., 0.)).xyz;
}

Ray normalize_ray(Ray r) {
    float len = length(r.d);
    r.d /= len;
    r.tmul /= len;
    return r;
}

// ---------------------------------------------------------------------------
// Surface intersection ------------------------------------------------------
// ---------------------------------------------------------------------------

// Intersection with some surface.
struct SurfaceIntersection {
    bool hit; // Is intersect.
    float t; // Distance to surface.
    float u; // X position on surface.
    float v; // Y position on surface.
    vec3 n; // Normal at intersection point.
};

// No intersection.
const SurfaceIntersection intersection_none = SurfaceIntersection(false, 1e10, 0., 0., vec3(0.));

SurfaceIntersection plane_intersect_normalized(Ray r) {
    float t = -r.o.z/r.d.z;
    if (t < 0.) {
        return intersection_none;
    } else {
        vec4 pos = r.o + r.d * t; 
        return SurfaceIntersection(true, t, pos.x, pos.y, vec3(0., 0., 1.));
    }
}

// Intersect ray with plane with matrix `inverse(plane)`, and `normal`.
SurfaceIntersection plane_intersect(Ray r, mat4 plane_inv, vec3 normal) {
    normal = normalize_normal(normal, r.d.xyz);
    r = transform(plane_inv, r);
    float len = length(r.d);
    r.d = normalize(r.d);

    SurfaceIntersection result = plane_intersect_normalized(r);
    if (result.hit) {
        result.t /= len;
        result.n = normal;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Color utils ---------------------------------------------------------------
// ---------------------------------------------------------------------------

// Forms color that next can be alpha-corrected. You should use this function instead of vec3(r, g, b), because of alpha-correction.
vec3 color(float r, float g, float b) {
    return vec3(r*r, g*g, b*b);
}

uniform int _grid_disable;
uniform int _angle_color_disable;

// Returns how this normal should change color.
float color_normal(vec3 normal, vec4 direction) {
    if (_angle_color_disable == 1) return 1.0;

    return abs(dot(normalize(direction.xyz), normalize(normal)));
}

// Returns grid color based on position and start color. Copy-pasted somewhere from shadertoy.
vec3 color_grid(vec3 start, vec2 uv) {
    if (_grid_disable == 1) return start;
    uv = fract(uv * 0.25);
    return start * mix(mix(0.7, 1.1, step(uv.x, 0.5)), mix(1.1, 0.7, step(uv.x, 0.5)), step(uv.y, 0.5));
}

// Adds color `b` to color `a` with coef, that must lie in [0..1]. If coef == 0, then result is `a`, if coef == 1.0, then result is `b`.
vec3 color_add_weighted(vec3 a, vec3 b, float coef) {
    return a*(1.0 - coef) + b*coef;
}

// ---------------------------------------------------------------------------
// Materials processing ------------------------------------------------------
// ---------------------------------------------------------------------------

uniform float _offset_after_material; // Normally should equals to 0.0001, but for mobile can be different

// Result after material processing.
struct MaterialProcessing {
    bool is_final; // If this flag set to false, then next ray tracing will be proceed. Useful for: portals, glass, mirrors, etc.
    vec3 mul_to_color; // If is_final = true, then this color is multiplied to current color, otherwise this is the final color.
    Ray new_ray; // New ray if is_final = true.
};

MaterialProcessing material_empty() {
    return MaterialProcessing(true, vec3(0.), ray_none);    
}

// Shortcut for creating material with is_final = true.
MaterialProcessing material_final(vec3 color) {
    return MaterialProcessing(true, color, ray_none);    
}

// Shortcut for creating material with is_final = false.
MaterialProcessing material_next(vec3 mul_color, Ray new_ray) {
    return MaterialProcessing(false, mul_color, new_ray);
}

// Function to easy write simple material.
MaterialProcessing material_simple(
    SurfaceIntersection hit, Ray r,
    vec3 color, float normal_coef, 
    bool grid, float grid_scale, float grid_coef
) {
    color = color_add_weighted(color, color * color_normal(hit.n, r.d), normal_coef);
    if (grid) {
        color = color_add_weighted(color, color_grid(color, vec2(hit.u, hit.v) * grid_scale), grid_coef);
    }
    return material_final(color);
}

// Function to easy write reflect material.
MaterialProcessing material_reflect(
    SurfaceIntersection hit, Ray r,
    vec3 add_to_color
) {
    r.d = vec4(my_reflect(r.d.xyz, hit.n), 0.);
    r.o += r.d * _offset_after_material;
    return material_next(add_to_color, r);
}

// Function to easy write refract material.
MaterialProcessing material_refract(
    SurfaceIntersection hit, Ray r,
    vec3 add_to_color, float refractive_index
) {
    r.d = vec4(my_refract(r.d.xyz, hit.n, refractive_index), 0.);
    r.o += r.d * _offset_after_material;
    return material_next(add_to_color, r);
}

MaterialProcessing material_teleport_transformed(Ray r) {
    // todo add add_gray_after_teleportation
    r.o += r.d * _offset_after_material;
    r = normalize_ray(r);
    return material_next(vec3(1.), r);
}

// Function to easy write teleport material.
MaterialProcessing material_teleport(
    SurfaceIntersection hit, Ray r,
    mat4 teleport_matrix
) {
    return material_teleport_transformed(transform(teleport_matrix, r));
}

// System materials
#define CUSTOM_MATERIAL -1
#define NOT_INSIDE 0
#define TELEPORT 1

// Actual predefined materials
#define DEBUG_RED 2
#define DEBUG_GREEN 3
#define DEBUG_BLUE 4

// User must use this offset for his materials
#define USER_MATERIAL_OFFSET 10

// ---------------------------------------------------------------------------
// Scene intersection --------------------------------------------------------
// ---------------------------------------------------------------------------

// Intersection with material.
struct SceneIntersection {
    int material;
    SurfaceIntersection hit;
};

const SceneIntersection scene_intersection_none = SceneIntersection(0, intersection_none);

bool nearer(SurfaceIntersection result, SurfaceIntersection current) {
    return current.hit && (current.t > 0.) && (!result.hit || (result.hit && current.t < result.t));
}

bool nearer(SceneIntersection result, SurfaceIntersection current) {
    return nearer(result.hit, current);
}

bool nearer(SceneIntersection result, SceneIntersection current) {
    return nearer(result, current.hit);
}

// Get capsule normal, thanks iq: https://www.shadertoy.com/view/Xt3SzX
vec3 cap_normal(vec3 pos, vec3 a, vec3 b, float radius) {
    vec3  ba = b - a;
    vec3  pa = pos - a;
    float h = clamp(dot(pa,ba)/dot(ba,ba),0.0,1.0);
    return (pa - h*ba)/radius;
}

// Get intersection with capsule, thanks iq: https://www.shadertoy.com/view/Xt3SzX
SurfaceIntersection cap(Ray r, vec3 pa, vec3 pb, float radius) {
    vec3 ro = r.o.xyz;
    vec3 rd = r.d.xyz;
    vec3 ba = pb - pa;
    vec3 oa = ro - pa;

    float baba = dot(ba,ba);
    float bard = dot(ba,rd);
    float baoa = dot(ba,oa);
    float rdoa = dot(rd,oa);
    float oaoa = dot(oa,oa);

    float a = baba      - bard*bard;
    float b = baba*rdoa - baoa*bard;
    float c = baba*oaoa - baoa*baoa - radius*radius*baba;
    float h = b*b - a*c;
    if( h>=0.0 ) {
        float t = (-b-sqrt(h))/a;
        float y = baoa + t*bard;
        // body
        if( y>0.0 && y<baba ) {
            vec3 pos = ro + rd * t;
            return SurfaceIntersection(true, t, 0., 0., cap_normal(pos, pa, pb, radius));
        }
        // caps
        vec3 oc = (y<=0.0) ? oa : ro - pb;
        b = dot(rd,oc);
        c = dot(oc,oc) - radius*radius;
        h = b*b - c;
        if( h>0.0 ) {
            t = -b - sqrt(h);
            vec3 pos = ro + rd * t;
            return SurfaceIntersection(true, t, 0., 0., cap_normal(pos, pa, pb, radius));
        };
    }
    return intersection_none;
}

// Get intersection with cylinder, thanks iq: https://www.shadertoy.com/view/4lcSRn
SurfaceIntersection cylinder(Ray r, vec3 pa, vec3 pb, float ra) {
    vec3 ro = r.o.xyz;
    vec3 rd = r.d.xyz;

    vec3 ba = pb-pa;

    vec3  oc = ro - pa;

    float baba = dot(ba,ba);
    float bard = dot(ba,rd);
    float baoc = dot(ba,oc);
    
    float k2 = baba            - bard*bard;
    float k1 = baba*dot(oc,rd) - baoc*bard;
    float k0 = baba*dot(oc,oc) - baoc*baoc - ra*ra*baba;
    
    float h = k1*k1 - k2*k0;
    if( h<0.0 ) return intersection_none;
    h = sqrt(h);

    // near side
    float t = (-k1-h)/k2;
    float y = baoc + t*bard;
    if( y>0.0 && y<baba ) return SurfaceIntersection(true, t, 0., 0., (oc+t*rd - ba*y/baba)/ra);
    
    // far side
    t = (-k1+h)/k2;
    y = baoc + t*bard;
    if( y>0.0 && y<baba ) return SurfaceIntersection(true, t, 0., 0., (oc+t*rd - ba*y/baba)/ra);
   
    return intersection_none;
}

// Triangle intersection. Returns { t, u, v }
SurfaceIntersection triangle(Ray r, vec3 v0, vec3 v1, vec3 v2) {
    vec3 ro = r.o.xyz;
    vec3 rd = r.d.xyz;

    vec3 v1v0 = v1 - v0;
    vec3 v2v0 = v2 - v0;
    vec3 rov0 = ro - v0;

    vec3  n = cross( v1v0, v2v0 );
    vec3  q = cross( rov0, rd );
    float d = 1.0/dot( rd, n );
    float u = d*dot( -q, v2v0 );
    float v = d*dot(  q, v1v0 );
    float t = d*dot( -n, rov0 );

    if( u<0.0 || v<0.0 || (u+v)>1.0 ) return intersection_none;

    return SurfaceIntersection(true, t, u, v, normalize_normal(cross(v1-v0, v2-v0), r.d.xyz));
}

// Intersect ray with debug thing
SceneIntersection debug_intersect(Ray r) {
    vec3 pa = vec3(0.);
    float radius = 0.03;

    SurfaceIntersection hit = intersection_none;
    SceneIntersection i = SceneIntersection(0, hit);

    hit = cap(r, pa, vec3(1., 0., 0.), radius);
    if (nearer(i, hit)) {
      i.material = DEBUG_RED;
      i.hit = hit;
    }

    hit = cap(r, pa, vec3(0., 1., 0.), radius);
    if (nearer(i, hit)) {
      i.material = DEBUG_GREEN;
      i.hit = hit;
    }

    hit = cap(r, pa, vec3(0., 0., 1.), radius);
    if (nearer(i, hit)) {
      i.material = DEBUG_BLUE;
      i.hit = hit;
    }

    return i;
}

// ---------------------------------------------------------------------------
// Code for current scene ----------------------------------------------------
// ---------------------------------------------------------------------------

SceneIntersection process_plane_intersection(SceneIntersection i, SurfaceIntersection hit, int inside) {
    if (inside == NOT_INSIDE) {
        // Not inside, do nothing
    } else if (inside == TELEPORT) {
        // This is wrong code, do nothing
    } else {
        i.hit = hit;
        i.material = inside;
    }
    return i;
}

SceneIntersection process_portal_intersection(SceneIntersection i, SurfaceIntersection hit, int inside, int teleport_material) {
    if (inside == NOT_INSIDE) {
        // Not inside, do nothing
    } else if (inside == TELEPORT) {
        i.hit = hit;
        i.material = teleport_material;
    } else {
        i.hit = hit;
        i.material = inside;
    }
    return i;
}

// ---------------------------------------------------------------------------
// Scene intersection with material ------------------------------------------
// ---------------------------------------------------------------------------

struct SceneIntersectionWithMaterial {
    SceneIntersection scene; // if scene.material == CUSTOM_MATERIAL, then material below is used
    MaterialProcessing material;
};
