---
name: Aarohi Aura
colors:
  surface: '#131313'
  surface-dim: '#131313'
  surface-bright: '#3a3939'
  surface-container-lowest: '#0e0e0e'
  surface-container-low: '#1c1b1b'
  surface-container: '#201f1f'
  surface-container-high: '#2a2a2a'
  surface-container-highest: '#353534'
  on-surface: '#e5e2e1'
  on-surface-variant: '#dbc2ad'
  inverse-surface: '#e5e2e1'
  inverse-on-surface: '#313030'
  outline: '#a38d7a'
  outline-variant: '#554334'
  surface-tint: '#ffb874'
  primary: '#ffbd7f'
  on-primary: '#4b2800'
  primary-container: '#ff9500'
  on-primary-container: '#643700'
  inverse-primary: '#8c5000'
  secondary: '#e2c1a0'
  on-secondary: '#412c15'
  secondary-container: '#5a4229'
  on-secondary-container: '#d0af8f'
  tertiary: '#8ad3ff'
  on-tertiary: '#00344a'
  tertiary-container: '#00bbfe'
  on-tertiary-container: '#004764'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#ffdcbf'
  primary-fixed-dim: '#ffb874'
  on-primary-fixed: '#2d1600'
  on-primary-fixed-variant: '#6a3b00'
  secondary-fixed: '#ffdcbb'
  secondary-fixed-dim: '#e2c1a0'
  on-secondary-fixed: '#291804'
  on-secondary-fixed-variant: '#5a4229'
  tertiary-fixed: '#c5e7ff'
  tertiary-fixed-dim: '#7fd0ff'
  on-tertiary-fixed: '#001e2d'
  on-tertiary-fixed-variant: '#004c6a'
  background: '#131313'
  on-background: '#e5e2e1'
  surface-variant: '#353534'
typography:
  display-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 48px
    fontWeight: '700'
    lineHeight: 56px
    letterSpacing: -0.02em
  display-lg-mobile:
    fontFamily: Plus Jakarta Sans
    fontSize: 36px
    fontWeight: '700'
    lineHeight: 44px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Plus Jakarta Sans
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  body-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 20px
    fontWeight: '400'
    lineHeight: 30px
  body-md:
    fontFamily: Plus Jakarta Sans
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  label-caps:
    fontFamily: Plus Jakarta Sans
    fontSize: 12px
    fontWeight: '700'
    lineHeight: 16px
    letterSpacing: 0.1em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  unit: 8px
  container-padding-mobile: 24px
  container-padding-desktop: 40px
  element-gap: 16px
  touch-target-min: 56px
---

## Brand & Style

The design system is centered on the concept of an "inner light" within a void. It targets users seeking a persistent, supportive presence during focused work or intense physical activity. The emotional response is one of calm reliability and human-centric warmth, moving away from the cold efficiency of traditional AI assistants.

The style is a blend of **Minimalism** and **Tactile Glassmorphism**. By using a near-black foundation, the interface recedes to the background, allowing the warm accent—representing the AI's persona—to become a beacon of interaction. High-contrast elements ensure visibility in high-glare environments like gyms, while soft, glowing edges create a sense of physical proximity and comfort.

## Colors

This design system utilizes a high-contrast, dark-first palette to minimize eye strain and maximize glanceability.

- **Primary (The Glow):** A warm, vibrant Amber (#FF9500) used exclusively for "Aarohi’s" presence, active states, and primary actions. It should feel like it emits light.
- **Secondary (The Hearth):** A deep, desaturated burnt umber (#2C1A05) used for subtle containers and depth, anchoring the primary glow.
- **Background (The Void):** A near-black (#0A0A0A) that provides the ultimate canvas for the amber accents.
- **Surface Labels:** High-purity white (#FFFFFF) for text to ensure AAA accessibility against the dark background.

## Typography

The typography uses **Plus Jakarta Sans** for its modern, friendly, and highly legible geometric forms. 

Scale is prioritized for "glanceability." In a gym context or from a desk-length distance, text must remain readable without effort. Large display sizes are used for the AI's responses to make the conversation feel present and significant. Line heights are generous to prevent visual clutter in high-activity environments. All labels and secondary information use a bold weight to maintain contrast against the dark UI.

## Layout & Spacing

The layout follows a **Fluid Grid** model with an emphasis on safe margins to prevent content from hitting the edges of mobile screens. 

- **Vertical Rhythm:** A strict 8px baseline grid ensures a consistent cadence between chat bubbles and action buttons.
- **Mobile:** 1-column layout with 24px side margins. Interactive elements (like the mic orb) are anchored to the bottom third for thumb-accessibility.
- **Desktop:** A centered, max-width container (800px) that mimics the intimacy of a mobile device while utilizing the extra horizontal space for supplemental "mood" visuals or history.
- **Touch Targets:** A minimum height of 56px is enforced for all interactive components to accommodate "heavy-handed" use during workouts.

## Elevation & Depth

Depth is achieved through **Tonal Layers** and **Ambient Glows** rather than traditional shadows. 

1. **The Base:** The #0A0A0A background represents the furthest depth.
2. **Plates:** Chat bubbles and containers use a slightly lighter, translucent black with a 1px stroke of #2C1A05. 
3. **The Aura:** The primary interactive element (the Mic Orb) uses a multi-layered box-shadow: a tight, intense amber glow (20px blur) and a wide, soft amber wash (80px blur at 20% opacity). This makes the element appear to illuminate the "table" it sits on.
4. **Active States:** When an element is focused, its border transitions from a dull umber to a vibrant amber glow.

## Shapes

The shape language is **Rounded**, favoring organic, approachable curves that feel soft to the touch. 

- **Chat Bubbles:** Use `rounded-lg` (16px) but with an asymmetric flare—the corner closest to the sender is more sharp (4px) to indicate directionality.
- **Buttons & Inputs:** Fully rounded "pill" shapes are avoided to maintain a sophisticated professional feel; instead, standard elements use a consistent 16px radius.
- **The Voice Orb:** Always a perfect circle, representing the holistic and centered nature of the AI.

## Components

- **The Voice Orb:** A persistent circular component at the bottom center. It pulsates with a soft Amber gradient when "listening" and expands into a horizontal waveform when "speaking."
- **Personal Chat Bubbles:** Aarohi’s messages are dark with a 1px Amber left-border. The user's messages are simple white outlines with no fill, keeping the focus on the AI's presence.
- **Primary Buttons:** High-contrast Amber fills with black text. No shadows; instead, they utilize an outer "glow" stroke when active.
- **Input Fields:** Minimal chrome. A single bottom-border that glows Amber when the keyboard is active.
- **Encouragement Chips:** Small, pill-shaped tags used for quick-replies or workout goals, using the Secondary "Hearth" color for the background to remain subtle but accessible.
- **Progress Rings:** Used for gym sets or focus timers; thin, high-glow Amber tracks that stand out sharply against the black void.