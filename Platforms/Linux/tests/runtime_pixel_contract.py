"""Contrast of rendered sRGB pixels, shared by native installed-runtime journeys."""

def pixel_contrast(first, second):
    def luminance(pixel):
        channels = [value / 255 for value in pixel[:3]]
        linear = [value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4
                  for value in channels]
        return sum(value * weight for value, weight in zip(linear, (.2126, .7152, .0722)))

    first_light, second_light = luminance(first), luminance(second)
    return (max(first_light, second_light) + .05) / (min(first_light, second_light) + .05)
