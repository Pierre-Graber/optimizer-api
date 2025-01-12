# Copyright © Mapotempo, 2019
#
# This file is part of Mapotempo.
#
# Mapotempo is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Mapotempo is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Mapotempo. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#

module DistanceMatrix
  extend ActiveSupport::Concern

  def compute_matrix(job_id = nil, &block)
    compute_need_matrix(job_id, &block)
  end

  private

  def compute_vrp_need_matrix
    [
      need_matrix_time? ? :time : nil,
      (need_matrix_time? || need_matrix_distance?) ? :distance : nil,
      need_matrix_value? ? :value : nil
    ].compact
  end

  def compute_need_matrix(job_id = nil, &block)
    vrp_need_matrix = compute_vrp_need_matrix
    need_matrix =
      vehicles.collect{ |vehicle| [vehicle, vehicle.dimensions] }.select{ |vehicle, dimensions|
        dimensions.find{ |dimension|
          vrp_need_matrix.include?(dimension) &&
            (vehicle.matrix_id.nil? || matrices.find{ |matrix| matrix.id == vehicle.matrix_id }.send(dimension).nil?) &&
            vehicle.send('need_matrix_' + dimension.to_s + '?')
        }
      }
    if !need_matrix.empty?
      matrix_points =
        points.collect.with_index{ |point, index|
          point.matrix_index = index
          [point.location.lat, point.location.lon]
        }

      uniq_need_matrix = need_matrix.collect{ |vehicle, dimensions|
        [vehicle.router_mode.to_sym, dimensions | vrp_need_matrix, vehicle.router_options]
      }.uniq

      i = 0
      uniq_need_matrix = Hash[uniq_need_matrix.collect{ |mode, dimensions, options|
        block&.call(nil, i += 1, uniq_need_matrix.size, 'compute matrix', nil, nil, nil)
        lats = matrix_points.map{ |pt| pt[0] }.sort
        lons = matrix_points.map{ |pt| pt[1] }.sort
        dist = distance(lats.last, lons.last, lats.first, lons.first)
        # set matrix_time and matrix_distance depending of dimensions order
        log "matrix computation #{matrix_points.size}x#{matrix_points.size} (#{dist} km) "\
            "-- #{services.size} services, #{vehicles.size} vehicles"

        Api::V01::APIBase.dump_vrp_dir.write(
          "#{job_id}_requests.curl", router.send('params', mode, dimensions.join('_'), options)
          .merge({ src: matrix_points.flatten.join(',') }.compact).to_json + "\n", { mode: 'a', gz: false }
        )

        tic = Time.now
        router_matrices = router.matrix(OptimizerWrapper.config[:router][:url],
                                        mode, dimensions, matrix_points, matrix_points, options)
        log "matrix computed in #{(Time.now - tic).round(2)} seconds"
        m = Models::Matrix.create(
          time: (router_matrices[dimensions.index(:time)] if dimensions.index(:time)),
          distance: (router_matrices[dimensions.index(:distance)] if dimensions.index(:distance)),
          value: (router_matrices[dimensions.index(:value)] if dimensions.index(:value))
        )
        if [m.time, m.distance, m.value].any?{ |matrix| matrix&.any?{ |row| row.any?(&:negative?) } }
          log 'Negative value provided by router' # TODO: fix this on the router-api side and turn this into an error
          [m.time, m.distance, m.value].each{ |matrix| matrix&.each{ |row| row.collect!(&:abs) } }
        end

        self.matrices += [m]
        [[mode, dimensions, options], m]
      }]

      uniq_need_matrix =
        need_matrix.collect{ |vehicle, dimensions|
          vehicle.matrix_id = matrices.find{ |matrix|
            matrix ==
              uniq_need_matrix[[vehicle.router_mode.to_sym, dimensions | vrp_need_matrix, vehicle.router_options]]
          }.id
        }
    end
  end

  def need_matrix_time?
    !(services.find{ |service|
      (service.activity ? [service.activity] : service.activities).any?{ |activity|
        !activity.timewindows.empty? || activity&.late_multiplier != 0
      }
    } ||
    vehicles.find(&:need_matrix_time?)).nil?
  end

  def need_matrix_distance?
    !vehicles.find(&:need_matrix_distance?).nil?
  end

  def need_matrix_value?
    false
  end

  def distance(lat1, lon1, lat2, lon2, unit = 'K')
    if (lat1 == lat2) && (lon1 == lon2)
      0
    else
      theta = lon1 - lon2
      dist = Math.sin(lat1 * Math::PI / 180) *
             Math.sin(lat2 * Math::PI / 180) +
             Math.cos(lat1 * Math::PI / 180) *
             Math.cos(lat2 * Math::PI / 180) *
             Math.cos(theta * Math::PI / 180)
      dist = Math.acos(dist)
      dist = dist * 180 / Math::PI
      miles = dist * 60 * 1.1515
      unit = unit.upcase

      if unit == 'K'
        (miles * 1.609344).round(2)
      elsif unit == 'N'
        (miles * 0.8684).round(2)
      else
        miles.round(2)
      end
    end
  end
end
