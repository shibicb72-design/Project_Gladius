"""Murmillo geometry in the runtime soldier's coordinates, facing -Z."""

import math

from soldier_geom import Soldier, box, cap, chain, loft, prism, rigid, ring, smoothstep


class Gladiator(Soldier):
    def __init__(self, design, lod, rests, segments):
        super().__init__(design, lod, rests)
        self.helmet_n, self.torso_n, self.limb_n = segments

    def build(self):
        self.helmet()
        self.neck()
        self.body()
        self.waist()
        for side in (-1, 1):
            self.limbs(side)
            self.hand(side)
            self.footwear(side)
        self.manica()
        self.greave()
        return self.g

    def band(self, rows, n, weights, style, power=2.0):
        """Rows contain ring centre and the three half widths."""
        rings = [ring(c, rx, front, back, n, power=power) for c, rx, front, back in rows]
        loft(self.g, rings, weights, style)
        return rings

    def helmet(self):
        g, n = self.g, self.helmet_n
        w = rigid("Head")
        cy = self.R["Head"][1]

        # The lower shell carries the head proxy, with a tall, flared bronze brim above the grille.
        # A3: the helmet "read large". The head hitbox is a 0.22 m sphere at the Head rest and the shell has to stay
        # outside it: the front already sat 3 mm off the sphere (no room), so only the sides (x 0.955) and the back
        # (x 0.96) come in, and what made the silhouette big goes down instead: the flared brim (0.258 -> 0.242 m),
        # the plume's width and the grille's stand-off. HEAD_R is asserted below.
        HEAD_R, SX, SB = .22, .955, .96

        def shell(y, x, front, back):
            return ((0, cy + y, 0), x * SX, front, back * SB)

        rows = [
            shell(.239, .013, .013, .013), shell(.224, .103, .104, .107),
            shell(.188, .167, .168, .173), shell(.126, .208, .21, .218),
            shell(.072, .226, .224, .232), shell(.025, .237, .222, .235),
            shell(-.076, .244, .224, .238), shell(-.149, .236, .215, .226),
            shell(-.205, .199, .190, .195), shell(-.229, .148, .152, .148),
        ]
        def shell_style(row, col):
            angle = math.tau * (col + .5) / n
            return "grille" if row in (4, 5, 6, 7) and math.sin(angle) < -.68 else "bronze"

        shell_rings = self.band(rows, n, w, shell_style, 2.5)
        cap(g, shell_rings[0], w, "bronze", True)
        cap(g, shell_rings[-1], w, "bronze", False)
        # every shell quad's centre (the nearest point of a facet of this convex shell, near enough) outside the hitbox
        nearest = 10.0
        for i in range(len(shell_rings) - 1):
            for j in range(n):
                quad = [shell_rings[i][j], shell_rings[i][(j + 1) % n],
                        shell_rings[i + 1][(j + 1) % n], shell_rings[i + 1][j]]
                mid = [sum(p[a] for p in quad) / 4.0 for a in range(3)]
                nearest = min(nearest, math.sqrt(mid[0] ** 2 + (mid[1] - cy) ** 2 + mid[2] ** 2))
        if nearest < HEAD_R + .001:
            raise ValueError("murmillo helmet shell enters the head hitbox: nearest facet %.4f m" % nearest)
        print("GLADIATOR_HELMET lod=%s nearest_facet_m=%.4f hitbox_radius_m=%.2f" % (
            "near" if self.detail() else "far", nearest, HEAD_R))
        brim = []
        BR = .242
        for offset, scale in ((.013, .90), (.004, 1.0), (-.009, 1.0), (-.016, .90)):
            points = ring((0, cy + .072 + offset, 0), BR * scale, BR * scale, BR * scale, n, power=2.5)
            brim.append([(x, y + .034 * z / BR - .016 * (x / BR) ** 2, z) for x, y, z in points])
        loft(g, brim, w, lambda row, _col: "trim" if row == 1 else "bronze")

        # The grille follows the visor's curvature. The dark shell behind the openings keeps the eyes recessed.
        def visor_depth(x):
            return -.238 + .90 * x * x

        def rail(a, b, width, style):
            x, y = a
            x2, y2 = b
            dx, dy = x2 - x, y2 - y
            length = math.hypot(dx, dy)
            sx, sy = -dy / length * width / 2, dx / length * width / 2
            outline = [(xx, yy, visor_depth(xx)) for xx, yy in
                       ((x+sx, y+sy), (x2+sx, y2+sy), (x2-sx, y2-sy), (x-sx, y-sy))]
            prism(g, outline, outline[0], (0, 0, -1), .006, w, style, inset=.12)

        count = 10 if self.detail() else 6
        for i in range(count + 1):
            x = -.161 + .322 * i / count
            rail((x, cy + .024), (x * .88, cy - .132), .009, "steel")
        for y, half, width, style in ((.027, .169, .017, "trim"), (-.018, .163, .010, "steel"),
                                      (-.066, .157, .011, "steel"), (-.132, .147, .016, "trim")):
            steps = count if self.detail() else count // 2
            for i in range(steps):
                rail((-half + 2 * half * i / steps, cy + y),
                     (-half + 2 * half * (i + 1) / steps, cy + y), width, style)
        for side in (-1, 1):
            rail((side * .168, cy + .027), (side * .145, cy - .13), .018, "trim")
            self.stud((side * .188 * SX, cy - .026, -.193), .015, w, "trim")
            if self.detail():
                for y in (-.047, -.098, -.145):
                    self.stud((side * .204 * SX, cy + y, -.164), .009, w, "steel")

        # The ridge and hand-cut plume use a narrow central strip above the proxy bound.
        stations = 30 if self.detail() else 12
        ridges = []
        for i in range(stations + 1):
            t = i / stations
            z = -.147 + .35 * t
            base = cy + .234 - .079 * abs(z / .205) ** 2
            # the crest rule (tests/test_soldier_glb.gd): the mesh stays within 2 cm of the helmet part boxes, whose
            # top is the crest's (cy + 0.35), so the plume keeps its height (0.34 less the 6 mm hand-cut steps);
            # round 1 had lowered it 4 cm and failed that test. Only its width comes in.
            top = cy + min(.34, .27 + .10 * math.sin(math.pi * t) ** .65 - .045 * t)
            top -= .003 * (i % 3) if self.detail() else 0.0
            width = .013 + .009 * math.sin(math.pi * t)
            ridges.append([(-.017, base - .008, z), (-width, top - .017, z),
                           (0, top, z + .013), (width, top - .017, z), (.017, base - .008, z)])
        plume = [[g.v(p, w(p)) for p in row] for row in ridges]
        for i in range(stations):
            for j in range(4):
                g.f([plume[i][j], plume[i][j+1], plume[i+1][j+1], plume[i+1][j]],
                    "plume", away=(0, ridges[i][0][1] - .025, ridges[i][0][2]))
        for i, orientation in ((0, 1), (-1, -2)):
            g.f(plume[i], "plume", away=ridges[orientation][2])

    def neck(self):
        face_start = len(self.g.faces)
        super().neck()
        for i in range(face_start, len(self.g.faces)):
            indices, _, shade = self.g.faces[i]
            self.g.faces[i] = (indices, "skin", shade)

    def body(self):
        # Broad shoulders, rib cage, waist and pelvis form one continuous loft.
        profile = [
            (1.483, .096, .080, .077), (1.462, .181, .108, .103), (1.424, .260, .130, .135),
            (1.387, .295, .154, .141), (1.353, .303, .173, .151), (1.307, .281, .174, .158),
            (1.238, .252, .158, .151),
            (1.176, .224, .138, .140), (1.102, .203, .125, .135), (1.027, .209, .134, .143),
            (.970, .228, .153, .162), (.907, .212, .141, .157), (.865, .150, .105, .125),
        ]
        torso = chain(["Chest", "Spine", "Hips"], [(1.317, .085), (1.125, .092)])

        def w(p):
            weights = torso(p)
            edge = smoothstep(.202, .303, abs(p[0])) * smoothstep(1.283, 1.398, p[1])
            if edge > 0:
                arm = "RightUpperArm" if p[0] > 0 else "LeftUpperArm"
                share = weights["Chest"] * edge * .72
                weights["Chest"] -= share
                weights[arm] = share
            return weights

        def style(row, _col):
            return "skin" if profile[row][0] > 1.027 else "cloth"

        rows = []
        for y, x, zf, zb in profile:
            points = ring((0, y, 0), x, zf, zb, self.torso_n, power=2.2)
            shaped = []
            for px, py, pz in points:
                if pz < 0:
                    pec = math.exp(-((abs(px) - .13) / .11) ** 2 - ((py - 1.33) / .079) ** 2)
                    abs_ridge = math.exp(-(px / .105) ** 2 - ((py - 1.16) / .07) ** 2)
                    pz -= .028 * pec + .016 * abs_ridge
                shaped.append((px, py, pz))
            rows.append(shaped)
        loft(self.g, rows, w, style)
        cap(self.g, rows[0], w, "skin", True)
        cap(self.g, rows[-1], w, "cloth", False)

    def waist(self):
        w = rigid("Hips")
        n = self.torso_n
        self.band([((0, y, 0), rx, rz, rz + .003) for y, rx, rz in
                   [(1.087, .211, .147), (1.080, .221, .155), (1.028, .231, .166),
                    (1.021, .222, .157)]], n, w,
                  lambda row, _col: "sash" if row == 1 else "leather", 2.4)
        for direction in (-1, 1):
            # Gathered fabric overlaps the fitted hip wrap in front and back.
            folds = 16 if self.detail() else 8
            rows = []
            for t in (0, .28, .58, .84, 1):
                line = []
                for i in range(folds + 1):
                    u = 2 * i / folds - 1
                    x = u * (.137 - .065 * t)
                    y = 1.037 - .202 * t + .042 * t * abs(u) + .008 * t * math.cos(i * 1.4)
                    z = direction * (.155 + .022 * math.sin(t * math.pi) - .026 * u * u
                                     + .014 * math.sin(i * math.pi / 2 + t) * math.sin(t * 2.2))
                    line.append((x, y, z))
                rows.append(line if direction < 0 else list(reversed(line)))
            loft(self.g, rows, w, "cloth", closed=False)
        box(self.g, (0, 1.055, -.172), (.082, .058, .032), w, "trim", chamfer=.5)
        box(self.g, (0, 1.055, -.191), (.046, .030, .009), w, "bronze", chamfer=.7)
        for x in (-.152, -.112, .112, .152):
            self.stud((x, 1.055, -.153 + x*x), .009, w, "bronze")

    def limbs(self, s):
        side, arm_axis = self._arm_axis(s)
        arm = [(1.520, .014), (1.501, .061), (1.464, .092), (1.421, .103), (1.379, .108), (1.313, .091),
               (1.246, .076), (1.187, .061), (1.140, .061), (1.085, .074),
               (1.038, .066), (.939, .049), (.858, .043), (.808, .041)]
        if not self.detail():
            arm = [arm[i] for i in (0, 2, 3, 5, 7, 8, 10, 12, 13)]
        aw = chain([side+"UpperArm", side+"ForeArm", side+"Hand"], [(1.14, .052), (.821, .023)])
        lifted = []
        for y, radius in arm:
            x, _, z = self._axis_at(arm_axis, y)
            x -= s * .038 * smoothstep(1.35, 1.50, y)
            lifted.append(((x, y, z), radius, radius * 1.02, radius * .94))
        arm_rings = self.band(lifted, self.limb_n, aw,
                              lambda row, _col: "linen" if s > 0 and 1.410 > arm[row][0] > .858 else "skin")
        cap(self.g, arm_rings[0], aw, "skin", True)
        _, leg_axis = self._leg_axis(s)
        leg = [(.984, .072, .101), (.929, .102, .105), (.858, .116, .118), (.779, .113, .111),
               (.683, .103, .089), (.586, .079, .080), (.506, .068, .076), (.452, .057, .062),
               (.380, .071, .084), (.305, .074, .080), (.218, .055, .056), (.133, .043, .046)]
        if not self.detail():
            leg = [leg[i] for i in (0, 2, 3, 4, 6, 7, 9, 11)]
        lw = chain(["Hips", side+"UpperLeg", side+"LowerLeg", side+"Foot"],
                   [(.923, .066), (.49, .071), (.11, .035)])
        self.band([(self._axis_at(leg_axis, y), x, z, z) for y, x, z in leg],
                  self.limb_n, lw, lambda row, _col: "cloth" if leg[row][0] > .858 else "skin")

    def manica(self):
        side, axis = self._arm_axis(1)
        # A3: (1) the elbow: the blend between upper arm and forearm is wider (0.076 -> 0.10) so three lames share
        # the bend, and the lames at the elbow are a little fuller, so the bent arm stays inside them. (Tried and
        # dropped in round 1: rigid per-lame weights. Bent 90 degrees the lames fanned out edge-on with skin between
        # them, worse than the smooth sleeve.) (2) the far LOD has 7 lames over the same length: each is now as
        # long as its spacing (x 1.06), so no arm padding shows between the plates.
        blend = chain([side+"UpperArm", side+"ForeArm"], [(1.14, .10)])
        rows = 10 if self.detail() else 7
        span = .528
        stretch = max(1.0, span / (rows - 1) * 1.06 / .061)
        for i in range(rows):
            t = i / (rows - 1)
            y = 1.391 - span * t
            mid_y = y - .030 * stretch
            base = .119 - .068 * t + .007 * math.exp(-((mid_y - 1.14) / .06) ** 2)
            w = blend
            self.band([(self._axis_at(axis, y + dy * stretch), r, r * 1.09, r) for dy, r in
                       [(0, base), (-.014, base + .009), (-.056, base + .006), (-.061, base)]],
                      self.limb_n, w, lambda row, _col: "trim" if row == 2 else "steel")
            if self.detail():
                x, _, z = self._axis_at(axis, y)
                for dx in (-.35, .35):
                    self.stud((x + dx * base, y - .038, z - base * 1.07), .008, w, "bronze")

    def greave(self):
        x, _, z = self.R["LeftLowerLeg"]
        w = rigid("LeftLowerLeg")
        outline = [(x + dx, y, depth + z) for dx, y, depth in
                   [(0, .506, -.093), (.056, .484, -.065), (.079, .435, -.044),
                    (.071, .302, -.06), (.051, .167, -.052), (.03, .133, -.057),
                    (-.03, .133, -.057), (-.051, .167, -.052), (-.071, .302, -.06),
                    (-.079, .435, -.044), (-.056, .484, -.065)]]
        prism(self.g, outline, outline[0], (0, 0, -1), .008, w, "trim")
        face = [(x + (px - x) * .85, .322 + (y - .322) * .93, depth - .010) for px, y, depth in outline]
        tip = self.g.v((x, .345, z - .121), w(None))
        indices = [self.g.v(p, w(p)) for p in face]
        for i in range(len(face)):
            self.g.f([tip, indices[i], indices[(i+1) % len(face)]], "bronze", away=(x, .31, z))
        for y, radius in ((.422, .081), (.203, .061)):
            self.band([((x, y + dy, z), radius, radius, radius) for dy in (.013, -.013)],
                      self.limb_n, w, "leather")
            self.stud((x, y, z - .114), .015, w, "trim")

    def footwear(self, side):
        start = len(self.g.faces)
        self.boot(side)
        for i in range(start, len(self.g.faces)):
            indices, style, shade = self.g.faces[i]
            y = sum(self.g.pos[index][1] for index in indices) / len(indices)
            style = "sole" if style == "suit" else ("linen" if y > .1 else "leather")
            self.g.faces[i] = (indices, style, shade)
        name = "Right" if side > 0 else "Left"
        x, _, z = self.R[name+"Foot"]
        # A3: the ankle wraps were two flat hoops and the instep "straps" three boxes sunk in the boot (they read
        # blocky). The hoops are rounded bands now (a raised middle row), and on the near LOD the instep carries
        # three leather straps that follow the boot's own cross-section from welt to welt, tied by a strap down
        # the ridge of the foot.
        w = rigid(name+"Foot")
        for y, radius in ((.140, .060), (.112, .067)):
            rows = ((.010, radius - .003), (0.0, radius + .003), (-.010, radius - .003)) if self.detail() \
                else ((.010, radius), (-.010, radius))
            self.band([((x, y + dy, z), r, r, r) for dy, r in rows], self.limb_n, w, "leather")
        if not self.detail():
            return
        rings = self.D["leg"]["boot"]  # [y, _, toe z, heel z, half width] from the sole up
        toes_from, toes_full = self.D["leg"]["toes_from_z"], self.D["leg"]["toes_full_z"]

        def w(p):  # the boot's own weights (Soldier.boot): the straps bend with the toes like the upper under them
            t = smoothstep(toes_from, toes_full, p[2])
            return {name+"Foot": 1.0 - t, name+"Toes": t}

        def half_width(y, zz):
            """The boot upper's half width at height y and depth zz (soldier_geom.Soldier.boot's outline)."""
            lo, hi = rings[0], rings[1]
            for a, b in zip(rings, rings[1:]):
                if y >= a[0]:
                    lo, hi = a, b
            t = min(1.0, max(0.0, (y - lo[0]) / (hi[0] - lo[0])))
            toe, heel, half = (lo[k] + (hi[k] - lo[k]) * t for k in (2, 3, 4))
            s = (zz - (toe + heel) * .5) / ((heel - toe) * .5)
            if abs(s) >= 1.0:
                return 0.0
            sa = abs(s) ** (1 / .9)
            return half * (1.0 if s < 0 else .88) * (1 - sa * sa) ** .4

        def ridge(zz):
            """The height of the boot's front slope at depth zz (where the outline's toe point passes zz)."""
            for a, b in zip(rings, rings[1:]):
                if min(a[2], b[2]) <= zz <= max(a[2], b[2]) and a[2] != b[2]:
                    return a[0] + (b[0] - a[0]) * (zz - a[2]) / (b[2] - a[2])
            return rings[-1][0]

        low = rings[0][0] + .012
        for zz in (-.186, -.160, -.134):
            top = ridge(zz)
            right = []
            for t in (0.0, .4, .7, .9):
                y = low + (top - low) * t
                right.append((half_width(y, zz), y))
            path = [(x + hx, y) for hx, y in right] + [(x, top)] + [(x - hx, y) for hx, y in reversed(right)]
            stations = []
            for px, py in path:
                nx, ny = px - x, (py - (low + top) * .5) * 1.3
                size = math.hypot(nx, ny) or 1.0
                stations.append(((px, py, zz), (nx / size, ny / size, 0.0)))
            self.strap(stations, (0.0, 0.0, 1.0), .006, .004, w, "leather")
        spine = []
        for zz in (-.184, -.164, -.144, -.124, -.106):  # stops short of the toe cap (round 1: it overhung it)
            spine.append(((x, ridge(zz), zz), (0.0, .92, -.39)))
        self.strap(spine, (1.0, 0.0, 0.0), .008, .006, w, "leather")

    def strap(self, stations, across, half, thick, w, style):
        """A leather strap: a closed rectangular tube along stations [(point on the surface, outward normal)],
        `half` wide each way along `across`, standing `thick` off the surface (and sunk 2 mm into it). Every face
        is wound to point away from the strap's own middle, so it cannot come out inside-out."""
        g = self.g
        sections = []
        for p, nrm in stations:
            corners = []
            for sign, lift in ((-1, -.002), (1, -.002), (1, thick), (-1, thick)):
                corners.append(tuple(p[a] + across[a] * half * sign + nrm[a] * lift for a in range(3)))
            sections.append(corners)
        index = [[g.v(c, w(c)) for c in corners] for corners in sections]
        for i in range(len(sections) - 1):
            middle = [sum(c[a] for c in sections[i] + sections[i + 1]) / 8.0 for a in range(3)]
            for j in range(4):
                k = (j + 1) % 4
                g.f([index[i][j], index[i][k], index[i + 1][k], index[i + 1][j]], style, away=middle)
        for i, other in ((0, 1), (-1, -2)):
            middle = [sum(c[a] for c in sections[i] + sections[other]) / 8.0 for a in range(3)]
            g.f(index[i], style, away=middle)

    def hand(self, side):
        start = len(self.g.faces)
        super().hand(side)
        for i in range(start, len(self.g.faces)):
            indices, style, shade = self.g.faces[i]
            self.g.faces[i] = (indices, "skin" if style == "suit" else "leather", shade)

    def stud(self, p, radius, w, style):
        n = 8 if self.detail() else 5
        x, y, z = p
        outline = [(x + radius * math.cos(math.tau * i / n),
                    y + radius * math.sin(math.tau * i / n), z) for i in range(n)]
        prism(self.g, outline, p, (0, 0, -1), radius * .34, w, style, inset=.31)
